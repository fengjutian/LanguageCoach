import 'dart:async';

import 'package:characters/characters.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:language_coach/core/ai/conversation_engine.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/structured_response_parser.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/models/conversation.dart';
import 'package:language_coach/core/network/api_client.dart';
import 'package:uuid/uuid.dart';

import '../../history/application/history_controller.dart';
import '../../settings/application/settings_controller.dart';
import 'chat_state.dart';
import 'conversation_providers.dart';

/// Hard cap on a single user message. The composer disables send past this,
/// and the controller refuses too so a programmatic caller can't bypass it.
const int kMaxUserMessageLength = 500;

final chatControllerProvider =
    NotifierProvider<ChatController, ChatState>(ChatController.new);

/// Owns the current conversation, its messages, the streaming lifecycle and
/// the language of the in-flight turn.
///
/// Invariants this controller is responsible for:
///
///  * **Epoch isolation.** Every send/load captures `epoch` and
///    `conversationId`. Callbacks re-check both before touching state, so a
///    slow reply for conversation A can never write into conversation B.
///  * **Captured persistence target.** The assistant message is written with
///    the conversation id captured at *send* time, never with whatever is
///    current when the stream finishes.
///  * **Captured language.** `resolvedTurnTargetLanguage` is resolved before
///    the request and reused for the request, the response label, the
///    persisted row and the language-mismatch check.
class ChatController extends Notifier<ChatState> {
  final _uuid = const Uuid();
  StreamSubscription<LlmEvent>? _replySubscription;

  /// Conversation id captured when the in-flight stream started.
  String? _streamingConversationId;

  /// Language captured when the in-flight stream started. Used to settle a
  /// cancelled turn even after the user switched conversations or languages.
  CoachLanguage? _streamingLanguage;

  ChatState get _s => state;

  /// Completes when no turn is in flight and no database write is pending.
  ///
  /// A turn counts as in flight from [send] until its assistant message is
  /// persisted (or it errors / is stopped). Callers that need a settled
  /// transcript — tests, "navigate away before saving" — await this instead
  /// of guessing at a delay.
  Future<void> get idle {
    if (_pendingWork == 0 && !_s.isStreaming) return Future<void>.value();
    return (_idleCompleter ??= Completer<void>()).future;
  }

  int _pendingWork = 0;
  Completer<void>? _idleCompleter;

  void _beginWork() {
    _pendingWork++;
    _idleCompleter ??= Completer<void>();
  }

  void _endWork() {
    if (_pendingWork > 0) _pendingWork--;
    if (_pendingWork > 0) return;
    final completer = _idleCompleter;
    _idleCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  ChatState build() {
    ref.onDispose(() {
      _replySubscription?.cancel();
      _replySubscription = null;
    });
    final settings = ref.read(settingsControllerProvider);
    return ChatState(
      conversationId: '',
      isDraft: true,
      conversationLanguage: settings.preferredLanguage,
      messages: const <ChatMessage>[],
      loadStatus: ChatLoadStatus.initial,
      isStreaming: false,
      epoch: 0,
    );
  }

  /// Cold-start hydration. Restores the last conversation, or seeds a fresh
  /// draft when there is nothing to restore.
  Future<void> initialize() async {
    final settings = ref.read(settingsControllerProvider);
    final lastId = settings.lastConversationId;
    if (!settings.saveHistory || lastId == null || lastId.trim().isEmpty) {
      _seedDraft();
      return;
    }
    await openConversation(lastId);
  }

  // ---------------------------------------------------------------- commands

  /// Start a blank conversation. Atomic: cancels in-flight generation, stops
  /// TTS and ASR, bumps the epoch so old callbacks die, mints a draft id and
  /// clears every piece of visible state. No database row is written until the
  /// first message is sent, so hammering the button creates no empty rows.
  Future<void> newConversation() async {
    await _cancelInFlight();
    await _newDraft();
  }

  /// Mint a draft conversation. [notice] survives the reset so "the
  /// conversation you asked for is gone, here is a blank one" is still on
  /// screen after the state is rebuilt.
  Future<void> _newDraft({String? notice}) async {
    final settings = ref.read(settingsControllerProvider);
    final id = _uuid.v4();
    state = ChatState(
      conversationId: id,
      isDraft: true,
      conversationLanguage: settings.preferredLanguage,
      messages: const <ChatMessage>[],
      loadStatus: ChatLoadStatus.ready,
      isStreaming: false,
      epoch: state.epoch + 1,
      error: notice,
    );
    await _persistLastConversationId(id);
  }

  /// Open an existing conversation. No-op when it is already current so the
  /// drawer can close without re-querying.
  Future<void> openConversation(String id) async {
    if (id.trim().isEmpty) return;
    if (id == state.conversationId &&
        state.loadStatus == ChatLoadStatus.ready) {
      return;
    }
    await _cancelInFlight();
    final epoch = state.epoch + 1;
    state = state.copyWith(
      conversationId: id,
      isDraft: false,
      messages: const <ChatMessage>[],
      loadStatus: ChatLoadStatus.loading,
      isStreaming: false,
      clearStreamingMessageId: true,
      clearLastUserMessageId: true,
      clearLastTurnLanguage: true,
      clearError: true,
      epoch: epoch,
    );

    final repo = ref.read(conversationRepositoryProvider);
    final Conversation? meta;
    final List<ChatMessage> messages;
    try {
      meta = await repo.getConversation(id);
      messages = await repo.messagesFor(id);
    } catch (e) {
      if (_stale(epoch)) return;
      state = state.copyWith(
        loadStatus: ChatLoadStatus.error,
        error: '加载对话失败：$e',
      );
      return;
    }

    // A slow load for conversation A must never clobber conversation B.
    if (_stale(epoch)) return;

    if (meta == null) {
      // The id in `lastConversationId` points at a row that no longer exists
      // (deleted here or on another device). Showing the previous transcript
      // would be a lie, so fall back to an empty draft — and keep saying so.
      await _newDraft(notice: '该对话已不存在，已为你新建对话。');
      return;
    }

    state = state.copyWith(
      isDraft: false,
      conversationLanguage: meta.targetLanguage,
      messages: List.unmodifiable(messages),
      loadStatus: ChatLoadStatus.ready,
      lastUserMessageId: _lastUserMessageIdOf(messages),
      clearError: true,
    );
    await _persistLastConversationId(id);
  }

  /// Switch this conversation's learning target. Persisted on the row when
  /// the conversation is not a draft, and *not* written to the global default
  /// — the settings page owns that.
  Future<void> setConversationLanguage(CoachLanguage language) async {
    if (state.conversationLanguage == language) return;
    state = state.copyWith(conversationLanguage: language);
    if (state.isDraft) return;
    final id = state.conversationId;
    try {
      await ref
          .read(conversationRepositoryProvider)
          .updateConversationLanguage(id, language);
      _refreshHistory();
    } catch (e) {
      // Non-fatal: the in-memory value is still correct for this session.
      _log('updateConversationLanguage failed', e);
    }
  }

  /// Send a user message. Returns silently when the text is empty, over the
  /// length cap, or a generation is already running.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.characters.length > kMaxUserMessageLength) return;
    if (state.isStreaming) return;

    final conversationId =
        state.conversationId.isEmpty ? _uuid.v4() : state.conversationId;
    final engine = ref.read(conversationEngineProvider);
    final resolved =
        engine.resolveTurnLanguage(trimmed, state.conversationLanguage);

    final userMessage = ChatMessage(
      id: 'u_${_uuid.v4()}',
      role: MessageRole.user,
      createdAt: DateTime.now(),
      sourceText: trimmed,
      status: ChatMessageStatus.completed,
    );
    final placeholder = ChatMessage(
      id: 'a_${_uuid.v4()}',
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      status: ChatMessageStatus.streaming,
    );

    final historyContext = _buildContext(
      // Exclude the message we are about to add: the provider appends the
      // current text itself, and passing it twice doubles the user's weight in
      // the prompt and confuses the language decision.
      messages: state.messages,
      excludeMessageId: userMessage.id,
    );

    state = state.copyWith(
      conversationId: conversationId,
      messages: List.unmodifiable(<ChatMessage>[
        ...state.messages,
        userMessage,
        placeholder,
      ]),
      isStreaming: true,
      streamingMessageId: placeholder.id,
      lastUserMessageId: userMessage.id,
      lastTurnLanguage: resolved.language,
      clearError: true,
    );

    _beginWork();
    final epoch = state.epoch;
    await _persistUserTurn(conversationId, userMessage, resolved.language);
    // The conversation may have been switched while the first message was
    // being written; streaming into a transcript the user left is exactly the
    // cross-conversation leak this controller exists to prevent.
    if (_stale(epoch)) {
      _endWork();
      return;
    }
    _streamReply(
      conversationId: conversationId,
      epoch: epoch,
      placeholderId: placeholder.id,
      text: trimmed,
      language: resolved.language,
      context: historyContext,
      userMessage: userMessage,
      isRegenerate: false,
    );
  }

  /// Re-answer the last user turn in place. Drops the previous assistant (or
  /// error) turn from the transcript *and* from SQLite instead of appending a
  /// duplicate question, which is what the old `retryLast()` did.
  Future<void> regenerateLast() async {
    if (state.isStreaming) return;
    final anchorId = state.lastUserMessageId;
    if (anchorId == null) return;
    final anchorIndex = state.messages.indexWhere((m) => m.id == anchorId);
    if (anchorIndex < 0) return;
    final anchor = state.messages[anchorIndex];
    final text = (anchor.sourceText ?? '').trim();
    if (text.isEmpty) return;

    await _cancelInFlight();

    final conversationId = state.conversationId;
    final epoch = state.epoch + 1;
    final engine = ref.read(conversationEngineProvider);
    final resolved =
        engine.resolveTurnLanguage(text, state.conversationLanguage);

    final kept = state.messages.sublist(0, anchorIndex + 1);
    final placeholder = ChatMessage(
      id: 'a_${_uuid.v4()}',
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      status: ChatMessageStatus.streaming,
    );
    final historyContext = _buildContext(
      messages: kept,
      excludeMessageId: anchor.id,
    );

    state = state.copyWith(
      messages: List.unmodifiable(<ChatMessage>[...kept, placeholder]),
      isStreaming: true,
      streamingMessageId: placeholder.id,
      lastUserMessageId: anchor.id,
      lastTurnLanguage: resolved.language,
      clearError: true,
      epoch: epoch,
    );

    _beginWork();
    _streamReply(
      conversationId: conversationId,
      epoch: epoch,
      placeholderId: placeholder.id,
      text: text,
      language: resolved.language,
      context: historyContext,
      userMessage: anchor,
      isRegenerate: true,
    );
  }

  /// Stop generation and settle the in-flight bubble so the transcript reads
  /// the same before and after an app restart.
  Future<void> stopGeneration() async {
    final placeholderId = state.streamingMessageId;
    final conversationId = _streamingConversationId ?? state.conversationId;
    final language = _streamingLanguage ?? state.conversationLanguage;
    await _replySubscription?.cancel();
    _replySubscription = null;
    _streamingConversationId = null;
    _streamingLanguage = null;
    if (placeholderId == null) {
      state = state.copyWith(isStreaming: false, clearStreamingMessageId: true);
      _endWork();
      return;
    }
    final settled = _settleCancelled(state.messages, placeholderId, language);
    state = state.copyWith(
      messages: settled.messages,
      isStreaming: false,
      clearStreamingMessageId: true,
    );
    await _persistCancelledTurn(
      conversationId: conversationId,
      message: settled.saved,
      isDraft: state.isDraft,
    );
    _endWork();
  }

  /// Called by the history layer after a conversation is deleted. Deleting the
  /// conversation the user is looking at must not leave the deleted transcript
  /// on screen, and must not let the next send resurrect the row through
  /// `ensureConversation()`.
  Future<void> handleConversationDeleted(String id) async {
    if (id != state.conversationId) return;
    await newConversation();
  }

  /// Bulk delete from the history page.
  Future<void> handleAllConversationsDeleted() async {
    await _cancelInFlight();
    _seedDraft();
    await _persistLastConversationId(state.conversationId);
  }

  // ------------------------------------------------------------- internals

  void _seedDraft() {
    state = ChatState(
      conversationId: _uuid.v4(),
      isDraft: true,
      conversationLanguage:
          ref.read(settingsControllerProvider).preferredLanguage,
      messages: const <ChatMessage>[],
      loadStatus: ChatLoadStatus.ready,
      isStreaming: false,
      epoch: state.epoch + 1,
    );
  }

  /// True when a callback belongs to a superseded conversation.
  bool _stale(int epoch) => epoch != state.epoch;

  List<ChatMessage> _buildContext({
    required List<ChatMessage> messages,
    String? excludeMessageId,
  }) {
    if (!ref.read(settingsControllerProvider).saveHistory) {
      return const <ChatMessage>[];
    }
    return ConversationEngine.usableContext(
      messages,
      excludeMessageId: excludeMessageId,
    );
  }

  String? _lastUserMessageIdOf(List<ChatMessage> messages) {
    for (final m in messages.reversed) {
      if (m.role == MessageRole.user) return m.id;
    }
    return null;
  }

  Future<void> _persistLastConversationId(String id) async {
    if (ref.read(settingsControllerProvider).lastConversationId == id) return;
    await ref
        .read(settingsControllerProvider.notifier)
        .persistLastConversationId(id);
  }

  /// First user message of a draft: create the row and insert the message in
  /// one transaction so a crash can't leave an empty conversation behind.
  Future<void> _persistUserTurn(
    String conversationId,
    ChatMessage userMessage,
    CoachLanguage language,
  ) async {
    if (!ref.read(settingsControllerProvider).saveHistory) return;
    final epoch = state.epoch;
    final wasDraft = state.isDraft;
    final repo = ref.read(conversationRepositoryProvider);
    final settings = ref.read(settingsControllerProvider);
    try {
      await repo.ensureConversation(
        conversationId,
        preferredLanguage: settings.preferredLanguage,
        targetLanguage: language,
      );
      await repo.appendMessage(
        conversationId: conversationId,
        message: userMessage,
      );
    } catch (e) {
      _log('persist user turn failed', e);
      return;
    }
    if (_stale(epoch)) return;
    if (wasDraft) {
      state = state.copyWith(isDraft: false);
      await _persistLastConversationId(conversationId);
    }
    _refreshHistory();
  }

  void _streamReply({
    required String conversationId,
    required int epoch,
    required String placeholderId,
    required String text,
    required CoachLanguage language,
    required List<ChatMessage> context,
    required ChatMessage userMessage,
    required bool isRegenerate,
  }) {
    _replySubscription?.cancel();
    _streamingConversationId = conversationId;
    _streamingLanguage = language;
    final engine = ref.read(conversationEngineProvider);
    final saveHistory = ref.read(settingsControllerProvider).saveHistory;

    /// Set once a terminal answer reached `_persistAssistant`, which owns
    /// releasing the turn's `idle` slot. Errors and empty completions have no
    /// assistant row to write, so `onDone` releases instead.
    var assistantPersisted = false;

    _replySubscription = engine
        .replyStream(
      text,
      conversationLanguage: language,
      overrideTargetLanguage: language,
      context: context,
    )
        .listen(
      (event) {
        if (_stale(epoch)) return;
        switch (event) {
          case LlmEventDelta(:final text):
            _appendDelta(placeholderId, text);
          case LlmEventThinking(:final text):
            _appendThinking(placeholderId, text);
          case LlmEventComplete(:final assistantMessage):
            _finalizeMessage(placeholderId, assistantMessage);
            // The turn stays "in flight" until its row is on disk, so a
            // caller awaiting [idle] cannot observe a UI state that SQLite
            // has not caught up with.
            assistantPersisted = true;
            unawaited(_persistAssistant(
              conversationId: conversationId,
              epoch: epoch,
              message: assistantMessage,
              userMessage: userMessage,
              language: language,
              isRegenerate: isRegenerate,
            ));
          case LlmEventError(:final error):
            _renderError(placeholderId, error);
        }
        if (event is LlmEventComplete || event is LlmEventError) {
          state = state.copyWith(clearStreamingMessageId: true);
        }
      },
      onError: (Object e) {
        if (_stale(epoch)) return;
        _renderError(
          placeholderId,
          LlmError(LlmErrorKind.unknown, e.toString()),
        );
      },
      onDone: () {
        if (_stale(epoch)) return;
        _streamingConversationId = null;
        _streamingLanguage = null;
        state = state.copyWith(
          isStreaming: false,
          clearStreamingMessageId: true,
        );
        // A failed turn never reaches `_persistAssistant`, so nothing else
        // would ever release its slot and `idle` would hang.
        if (!assistantPersisted || !saveHistory) _endWork();
      },
    );
  }

  void _appendDelta(String messageId, String delta) {
    final next = _mapMessage(messageId, (current) {
      final response = current.response ?? _emptyResponse();
      return current.copyWith(
        response: response.copyWith(primary: response.primary + delta),
      );
    });
    if (next != null) state = state.copyWith(messages: next);
  }

  void _appendThinking(String messageId, String delta) {
    final next = _mapMessage(messageId, (current) {
      final response = current.response ?? _emptyResponse();
      return current.copyWith(
        response: response.copyWith(thinking: response.thinking + delta),
      );
    });
    if (next != null) state = state.copyWith(messages: next);
  }

  void _finalizeMessage(String messageId, ChatMessage finalized) {
    final next = _mapMessage(
      messageId,
      (_) => finalized.copyWith(
        id: messageId,
        status: ChatMessageStatus.completed,
      ),
    );
    if (next != null) state = state.copyWith(messages: next);
  }

  void _renderError(String messageId, LlmError error) {
    final next = _mapMessage(
      messageId,
      (current) => ChatMessage(
        id: current.id,
        role: MessageRole.error,
        createdAt: current.createdAt,
        sourceText: describeLlmError(error),
        status: ChatMessageStatus.failed,
      ),
    );
    if (next != null) {
      state = state.copyWith(
        messages: next,
        isStreaming: false,
        clearStreamingMessageId: true,
      );
    }
  }

  /// Replace one message in place. Returns `null` when the id vanished, which
  /// happens legitimately when the user switched conversations mid-stream.
  List<ChatMessage>? _mapMessage(
    String messageId,
    ChatMessage Function(ChatMessage) transform,
  ) {
    final index = state.messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return null;
    final copy = List<ChatMessage>.from(state.messages);
    copy[index] = transform(copy[index]);
    return List.unmodifiable(copy);
  }

  CoachResponse _emptyResponse() => CoachResponse(
        intent: CoachIntent.conversation,
        sourceLanguage: 'auto',
        targetLanguage: '',
        primary: '',
        explanation: '',
        sentences: const <CoachSentence>[],
      );

  Future<void> _persistAssistant({
    required String conversationId,
    required int epoch,
    required ChatMessage message,
    required ChatMessage userMessage,
    required CoachLanguage language,
    required bool isRegenerate,
  }) async {
    if (!ref.read(settingsControllerProvider).saveHistory) return;
    final repo = ref.read(conversationRepositoryProvider);
    final settings = ref.read(settingsControllerProvider);
    try {
      if (isRegenerate) {
        await repo.replaceAssistantTurn(
          conversationId: conversationId,
          userMessageId: userMessage.id,
          assistant: message,
        );
      } else {
        await repo.ensureConversation(
          conversationId,
          preferredLanguage: settings.preferredLanguage,
          targetLanguage: language,
        );
        await repo.appendMessage(
          conversationId: conversationId,
          message: message,
        );
      }
      await _autoTitle(conversationId, userMessage);
    } catch (e) {
      _log('persist assistant failed', e);
      _endWork();
      return;
    }
    if (!_stale(epoch)) _refreshHistory();
    _endWork();
  }

  /// Title the conversation after its first user message. Only touches an
  /// auto-generated placeholder title, never a title the user set.
  Future<void> _autoTitle(
    String conversationId,
    ChatMessage userMessage,
  ) async {
    final text = (userMessage.sourceText ?? '').trim();
    if (text.isEmpty) return;
    final repo = ref.read(conversationRepositoryProvider);
    final meta = await repo.getConversation(conversationId);
    if (meta == null || !isAutoTitle(meta.title)) return;
    await repo.updateTitle(conversationId, shortConversationTitle(text));
  }

  /// Turn cancellation into a durable, coherent turn instead of an in-memory
  /// placeholder that disappears on restart. A half-streamed OpenAI-compatible
  /// reply is raw JSON scaffold (`{"intent":…,"primary":"It is`), which must
  /// never become the persisted answer.
  ({List<ChatMessage> messages, ChatMessage? saved}) _settleCancelled(
    List<ChatMessage> messages,
    String messageId,
    CoachLanguage language,
  ) {
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return (messages: messages, saved: null);
    final current = messages[index];
    final raw = (current.response?.primary ?? '').trim();
    if (raw.isEmpty) {
      // Nothing usable arrived: drop the bubble entirely so the transcript has
      // the same shape live and after a restart.
      final copy = List<ChatMessage>.from(messages)..removeAt(index);
      return (messages: List.unmodifiable(copy), saved: null);
    }

    final parsed = const StructuredResponseParser().parse(
      raw,
      intent: current.response?.intent ?? CoachIntent.conversation,
      targetLanguage: language,
    );
    // A partial JSON object decodes to itself, so "primary == raw" plus a
    // leading brace means we only have scaffold, not an answer.
    final isTruncatedJson = parsed.primary.trim() == raw &&
        (raw.startsWith('{') || raw.contains('"primary"'));
    final kept = isTruncatedJson ? '' : parsed.primary.trim();

    final settled = current.copyWith(
      status: ChatMessageStatus.cancelled,
      response: (current.response ?? parsed).copyWith(
        primary: kept.isEmpty ? '已停止生成，没有收到完整回复。' : kept,
        sentences: const <CoachSentence>[],
        explanation:
            isTruncatedJson ? '本次生成被手动停止，回复内容不完整。' : parsed.explanation,
        targetLanguage: language.code,
      ),
      // A cancelled answer is never offered as context to the next request.
      languageMismatch: false,
    );
    final copy = List<ChatMessage>.from(messages);
    copy[index] = settled;
    // Only persist a cancelled turn that actually carries content. A
    // "已停止生成" stub saved to SQLite would show up as a real answer after a
    // restart and, worse, would read as a completed turn.
    final saveable = !isTruncatedJson && kept.isNotEmpty;
    return (
      messages: List.unmodifiable(copy),
      saved: saveable ? settled : null,
    );
  }

  Future<void> _persistCancelledTurn({
    required String conversationId,
    required ChatMessage? message,
    required bool isDraft,
  }) async {
    if (message == null) return;
    if (isDraft || !ref.read(settingsControllerProvider).saveHistory) return;
    try {
      await ref
          .read(conversationRepositoryProvider)
          .appendMessage(conversationId: conversationId, message: message);
    } catch (e) {
      _log('persist cancelled turn failed', e);
    }
  }

  Future<void> _cancelInFlight() async {
    final hadStream = _replySubscription != null;
    await _replySubscription?.cancel();
    _replySubscription = null;
    _streamingConversationId = null;
    _streamingLanguage = null;
    // The abandoned turn never reaches its own terminal event, so release its
    // `idle` slot here — otherwise a caller awaiting `idle` after switching
    // conversations would wait forever.
    if (hadStream) _endWork();
    // Audio playback and dictation are session-scoped UI concerns and own
    // their own platform channels; `ChatPage` stops them on the same epoch
    // change that this method triggers. Reaching in from here would drag the
    // audio stack (and its platform bindings) into every controller test.
  }

  void _refreshHistory() {
    ref.invalidate(historyControllerProvider);
  }

  void _log(String message, Object error) {
    // ignore: avoid_print
    print('[ChatController] $message: $error');
  }
}

/// Shared with the chat page so the composer, the empty state and the
/// drawer's "new conversation" button all produce identical titles.
String shortConversationTitle(String sourceText) {
  final trimmed = sourceText.trim();
  if (trimmed.length <= 18) return trimmed;
  return '${trimmed.substring(0, 18)}…';
}

/// True for the placeholder titles the repository generates, i.e. a
/// conversation that has not been named by the user or by the chat page.
bool isAutoTitle(String? title) {
  if (title == null) return false;
  return RegExp(r'^对话 \d{2}-\d{2} \d{2}:\d{2}$').hasMatch(title);
}

/// Delete a conversation through the history layer, then reconcile the chat
/// state. Both the drawer and the History tab route through this one command
/// so "delete the conversation I am reading" can never leave a deleted
/// transcript on screen or resurrect the row on the next send.
Future<void> deleteConversationAndSync(
    WidgetRef ref, String conversationId) async {
  await ref
      .read(historyControllerProvider.notifier)
      .deleteConversation(conversationId);
  await ref
      .read(chatControllerProvider.notifier)
      .handleConversationDeleted(conversationId);
}

/// Bulk delete. Same reconciliation as the single-conversation path.
Future<void> deleteAllConversationsAndSync(WidgetRef ref) async {
  await ref.read(historyControllerProvider.notifier).deleteAll();
  await ref
      .read(chatControllerProvider.notifier)
      .handleAllConversationsDeleted();
}

/// Localised, user-facing rendering of a provider failure. Lives here so the
/// controller, the error bubble and tests all agree on one string per kind.
String describeLlmError(LlmError error) {
  return switch (error.kind) {
    LlmErrorKind.unauthorized => '未授权：请检查 API Key',
    LlmErrorKind.rateLimited => '请求过于频繁，请稍后再试',
    LlmErrorKind.timeout => '请求超时，请检查网络',
    LlmErrorKind.network => '网络不可用',
    LlmErrorKind.format => '模型返回格式异常',
    LlmErrorKind.server => '上游服务异常',
    LlmErrorKind.cancelled => '已取消',
    LlmErrorKind.unknown => '未知错误',
  };
}
