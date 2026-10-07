import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/conversation_repository.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/models/conversation.dart';
import 'package:language_coach/core/network/api_client.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/chat/application/chat_controller.dart';
import 'package:language_coach/features/chat/application/chat_state.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/history/application/history_controller.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';

/// Provider whose completion is driven by the test: it records the request it
/// received, then waits on its own gate before emitting the final answer.
/// This is what makes the epoch / cross-conversation write assertions
/// deterministic instead of "fast enough to usually pass".
/// Scripted provider. In [manual] mode it hands back a controller the test
/// drives explicitly; otherwise it answers immediately.
///
/// It deliberately does **not** park inside an `async*` body awaiting a
/// completer: cancelling such a subscription never completes, which would
/// hang every `stopGeneration` / switch test instead of exercising them.
class _ScriptedProvider implements LlmProvider {
  _ScriptedProvider({this.manual = false});

  final bool manual;

  static const String _defaultPrimary = 'It is raining today.';

  final List<CoachRequest> requests = <CoachRequest>[];
  final List<List<ChatMessage>> contexts = <List<ChatMessage>>[];
  final List<_Turn> turns = <_Turn>[];

  @override
  String get id => 'scripted';

  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) {
    requests.add(request);
    contexts.add(context);
    final turn = _Turn(request, _defaultPrimary);
    turns.add(turn);
    if (manual) return turn.stream;
    scheduleMicrotask(turn.complete);
    return turn.stream;
  }

  /// Release the newest turn, the way a real network response would arrive.
  void completeLast() => turns.last.complete();

  void failLast(LlmError error) => turns.last.fail(error);
}

/// One request/response exchange under test control.
class _Turn {
  _Turn(this.request, this.primary);

  final CoachRequest request;
  final String primary;
  final StreamController<LlmEvent> _controller = StreamController<LlmEvent>();
  bool _closed = false;

  Stream<LlmEvent> get stream => _controller.stream;

  /// Partial answer text, the way a real provider streams it.
  void emitDelta(String text) {
    if (_closed) return;
    _controller.add(LlmEventDelta(text));
  }

  void complete([String? answer]) {
    final text = answer ?? primary;
    if (_closed) return;
    _closed = true;
    _controller.add(LlmEventDelta(text));
    final response = CoachResponse(
      intent: request.intent,
      sourceLanguage: 'auto',
      targetLanguage: 'en',
      primary: text,
      explanation: 'because',
      sentences: <CoachSentence>[CoachSentence(id: 's1', text: text)],
    );
    _controller.add(LlmEventComplete(
      response,
      ChatMessage(
        id: 'm_${request.text.hashCode}',
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: response,
        model: 'scripted',
        status: ChatMessageStatus.completed,
      ),
    ));
    unawaited(_controller.close());
  }

  void fail(LlmError error) {
    if (_closed) return;
    _closed = true;
    _controller.add(LlmEventError(error));
    unawaited(_controller.close());
  }
}

class _Harness {
  _Harness({
    CoachLanguage? globalLanguage,
    bool saveHistory = true,
    bool manualProvider = false,
  }) : store = InMemoryConversationRepository() {
    repository = _GatedRepository(store);
    provider = _ScriptedProvider(manual: manualProvider);
    settings = AppSettings.defaults.copyWith(
      preferredLanguage: globalLanguage ?? CoachLanguage.english,
      saveHistory: saveHistory,
    );
  }

  final InMemoryConversationRepository store;
  late final _GatedRepository repository;
  late final _ScriptedProvider provider;
  late final AppSettings settings;

  ProviderContainer build() {
    final container = ProviderContainer(
      overrides: [
        conversationRepositoryProvider.overrideWithValue(repository),
        settingsRepositoryProvider
            .overrideWithValue(InMemorySettingsRepository()),
        llmRouterProvider.overrideWithValue(
          LlmRouter(
            manualMiniMax: provider,
            manualDeepSeek: provider,
            localQwen: provider,
          ),
        ),
        settingsControllerProvider.overrideWith(() => _Seeded(settings)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ChatController controllerOf(ProviderContainer c) =>
      c.read(chatControllerProvider.notifier);

  ChatState stateOf(ProviderContainer c) => c.read(chatControllerProvider);

  /// Wait for the in-flight turn *and* its database write to settle.
  Future<void> settle(ProviderContainer c) =>
      c.read(chatControllerProvider.notifier).idle;

  /// Send and wait until the turn is fully persisted, so assertions can read
  /// a coherent UI + database pair without guessing at delays.
  Future<void> send(ProviderContainer c, String text) async {
    await c.read(chatControllerProvider.notifier).send(text);
    await settle(c);
  }

  Future<void> regenerate(ProviderContainer c) async {
    await c.read(chatControllerProvider.notifier).regenerateLast();
    await settle(c);
  }

  /// `ConversationEngine.replyStream` is an `async*` generator, so its body —
  /// and therefore the provider call — starts one microtask after the
  /// subscription. Manual-mode tests must wait for the turn to exist before
  /// driving it.
  Future<void> waitForRequest({int count = 1}) async {
    for (var i = 0; i < 50 && provider.requests.length < count; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(provider.requests.length, greaterThanOrEqualTo(count));
  }
}

/// Mirrors the production startup path: `main()` seeds the controller with
/// settings already loaded from SQLite.
class _Seeded extends SettingsController {
  _Seeded(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;
}

ChatMessage _user(String id, String text, {DateTime? at}) => ChatMessage(
      id: id,
      role: MessageRole.user,
      createdAt: at ?? DateTime(2026),
      sourceText: text,
    );

ChatMessage _assistant(
  String id,
  String text, {
  DateTime? at,
  String language = 'en',
  ChatMessageStatus status = ChatMessageStatus.completed,
}) =>
    ChatMessage(
      id: id,
      role: MessageRole.assistant,
      createdAt: at ?? DateTime(2026),
      status: status,
      response: CoachResponse(
        intent: CoachIntent.conversation,
        sourceLanguage: 'auto',
        targetLanguage: language,
        primary: text,
        explanation: '',
        sentences: <CoachSentence>[CoachSentence(id: 's_$id', text: text)],
      ),
    );

/// Seed a persisted conversation with one completed exchange.
Future<void> _seedConversation(
  ConversationRepository repo,
  String id, {
  CoachLanguage language = CoachLanguage.japanese,
  String userText = '你好',
  String answer = 'こんにちは',
}) async {
  await repo.ensureConversation(
    id,
    title: 'seed',
    preferredLanguage: CoachLanguage.english,
    targetLanguage: language,
  );
  await repo.appendMessage(
    conversationId: id,
    message: _user('u_$id', userText),
  );
  await repo.appendMessage(
    conversationId: id,
    message: _assistant(
      'a_$id',
      answer,
      language: language.code,
      at: DateTime(2026, 1, 1, 0, 0, 1),
    ),
  );
}

void main() {
  group('initialize / hydrate', () {
    test('restores the last conversation and its messages', () async {
      final h = _Harness();
      final container = h.build();
      await _seedConversation(h.repository, 'c1');
      container
          .read(settingsControllerProvider.notifier)
          .setLastConversationId('c1');

      await h.controllerOf(container).initialize();

      final state = h.stateOf(container);
      expect(state.conversationId, 'c1');
      expect(state.isDraft, isFalse);
      expect(state.messages.length, 2);
      expect(state.loadStatus, ChatLoadStatus.ready);
      expect(state.lastUserMessageId, 'u_c1');
    });

    test('seeds a blank draft when there is nothing to restore', () async {
      final h = _Harness();
      final container = h.build();

      await h.controllerOf(container).initialize();

      final state = h.stateOf(container);
      expect(state.conversationId, isNotEmpty);
      expect(state.isDraft, isTrue);
      expect(state.messages, isEmpty);
      expect(state.conversationLanguage, CoachLanguage.english);
    });

    test('missing conversation row falls back to a fresh draft', () async {
      final h = _Harness();
      final container = h.build();
      container
          .read(settingsControllerProvider.notifier)
          .setLastConversationId('deleted-elsewhere');

      await h.controllerOf(container).initialize();

      final state = h.stateOf(container);
      expect(state.isDraft, isTrue);
      expect(state.messages, isEmpty);
      expect(state.error, contains('已不存在'));
    });
  });

  group('newConversation', () {
    test('mints a new id and clears every trace of the old conversation',
        () async {
      final h = _Harness();
      final container = h.build();
      await _seedConversation(h.repository, 'c1');
      await h.controllerOf(container).openConversation('c1');
      final before = h.stateOf(container).conversationId;
      expect(h.stateOf(container).messages, isNotEmpty);

      await h.controllerOf(container).newConversation();

      final state = h.stateOf(container);
      expect(state.conversationId, isNot(before));
      expect(state.messages, isEmpty);
      expect(state.isDraft, isTrue);
      expect(state.isStreaming, isFalse);
      expect(state.lastUserMessageId, isNull);
      expect(state.streamingMessageId, isNull);
      expect(state.error, isNull);
    });

    test('repeated taps never create empty database rows', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);

      await controller.initialize();
      final firstId = h.stateOf(container).conversationId;
      await controller.newConversation();
      await controller.newConversation();

      expect(h.stateOf(container).conversationId, isNot(firstId));
      expect(await h.repository.recentConversations(), isEmpty);
    });

    test('persists the new id as the last conversation', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);

      await controller.initialize();
      await controller.newConversation();

      expect(
        container.read(settingsControllerProvider).lastConversationId,
        h.stateOf(container).conversationId,
      );
    });
  });

  group('send', () {
    test('first message materialises the draft and belongs to it', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final draftId = h.stateOf(container).conversationId;

      await h.send(container, 'hello');

      final persisted = await h.repository.messagesFor(draftId);
      expect(persisted.where((m) => m.role == MessageRole.user).length, 1);
      expect(h.stateOf(container).isDraft, isFalse);
      expect(h.stateOf(container).messages.length, 2);
      expect(await h.repository.recentConversations(), hasLength(1));
    });

    test('a second message after new-conversation never lands in the old row',
        () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final firstDraft = h.stateOf(container).conversationId;
      await h.send(container, 'first');

      await controller.newConversation();
      final secondDraft = h.stateOf(container).conversationId;
      await h.send(container, 'second');

      expect(
        (await h.repository.messagesFor(firstDraft))
            .where((m) => m.sourceText == 'second'),
        isEmpty,
      );
      expect(
        (await h.repository.messagesFor(secondDraft))
            .where((m) => m.sourceText == 'second'),
        hasLength(1),
      );
    });

    test('refuses blank input and over-length input', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      await h.send(container, '   ');
      expect(h.stateOf(container).messages, isEmpty);

      await h.send(container, 'x' * (kMaxUserMessageLength + 1));
      expect(h.stateOf(container).messages, isEmpty);
      expect(h.provider.requests, isEmpty);
    });

    test('refuses a second send while a reply is streaming', () async {
      final h = _Harness(manualProvider: true);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      await controller.send('one');
      await h.waitForRequest();
      await controller.send('two');
      await Future<void>.delayed(Duration.zero);

      expect(h.provider.requests, hasLength(1));
      expect(
        h.stateOf(container).messages.where((m) => m.role == MessageRole.user),
        hasLength(1),
      );
    });

    test('captures the resolved turn language for request, label and DB row',
        () async {
      final h = _Harness(globalLanguage: CoachLanguage.japanese);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      await h.send(container, '今天天气怎么样');

      expect(h.provider.requests.single.targetLanguage, CoachLanguage.japanese);
      expect(h.stateOf(container).lastTurnLanguage, CoachLanguage.japanese);
      final conversation = await h.repository
          .getConversation(h.stateOf(container).conversationId);
      expect(conversation?.targetLanguage, CoachLanguage.japanese);
    });

    test('an explicit language in the text overrides the conversation one',
        () async {
      final h = _Harness(globalLanguage: CoachLanguage.japanese);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      await h.send(container, '用英语怎么说"你好"');

      expect(h.provider.requests.single.targetLanguage, CoachLanguage.english);
      expect(h.stateOf(container).lastTurnLanguage, CoachLanguage.english);
    });

    test('auto-titles the conversation from the first user message', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final id = h.stateOf(container).conversationId;

      await h.send(container, '今天下雨了怎么表达');

      final meta = await h.repository.getConversation(id);
      expect(meta?.title, '今天下雨了怎么表达');
      expect(isAutoTitle(meta?.title), isFalse);
    });
  });

  group('context hygiene', () {
    test('does not repeat the current user message or include the placeholder',
        () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      await h.send(container, 'first question');

      await h.send(container, 'second question');

      final context = h.provider.contexts.last;
      expect(
        context.where((m) => m.sourceText == 'second question'),
        isEmpty,
        reason: 'the current turn travels in the request, not in history',
      );
      expect(
        context.where((m) => m.status != ChatMessageStatus.completed),
        isEmpty,
        reason: 'streaming placeholders must never enter context',
      );
      expect(
        context.where((m) => m.sourceText == 'first question'),
        hasLength(1),
      );
    });

    test('drops error rows and half-finished turns from context', () async {
      final h = _Harness();
      final container = h.build();
      await _seedConversation(h.repository, 'c1');
      await h.repository.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: 'u_err',
          role: MessageRole.user,
          createdAt: DateTime(2026, 1, 1, 0, 0, 2),
          sourceText: 'boom',
        ),
      );
      await h.repository.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: 'a_err',
          role: MessageRole.error,
          createdAt: DateTime(2026, 1, 1, 0, 0, 3),
          sourceText: '网络不可用',
          status: ChatMessageStatus.failed,
        ),
      );
      await h.controllerOf(container).openConversation('c1');

      await h.send(container, 'follow up');

      final context = h.provider.contexts.single;
      expect(context.any((m) => m.role == MessageRole.error), isFalse);
      expect(context.any((m) => m.id == 'a_err'), isFalse);
      // The question whose answer failed stays: it is a valid user turn.
      expect(context.any((m) => m.id == 'u_err'), isTrue);
    });
  });

  group('epoch isolation', () {
    test('a slow load for A cannot overwrite B', () async {
      final h = _Harness();
      final container = h.build();
      await _seedConversation(h.repository, 'cA', userText: 'A');
      await _seedConversation(h.repository, 'cB', userText: 'B');

      final controller = h.controllerOf(container);
      // Hold A's load, let B's complete, then release A.
      h.repository.armNextLoad();
      final first = controller.openConversation('cA');
      final second = controller.openConversation('cB');
      h.repository.release();
      await Future.wait(<Future<void>>[first, second]);

      final state = h.stateOf(container);
      expect(state.conversationId, 'cB');
      expect(
        state.messages.where((m) => m.sourceText == 'B'),
        hasLength(1),
      );
      expect(
        state.messages.where((m) => m.sourceText == 'A'),
        isEmpty,
      );
    });

    test('a reply that finishes after switching conversations is discarded',
        () async {
      // Manual provider: the reply only arrives once the test says so, which
      // is the whole point — a fast fake would hide the stale-callback bug.
      final h = _Harness(manualProvider: true);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final firstId = h.stateOf(container).conversationId;

      await controller.send('question for the first conversation');
      await h.waitForRequest();
      expect(h.stateOf(container).isStreaming, isTrue);

      await controller.newConversation();
      final secondId = h.stateOf(container).conversationId;

      // The abandoned reply lands now — far too late to matter.
      h.provider.completeLast();
      await Future<void>.delayed(Duration.zero);

      final state = h.stateOf(container);
      expect(state.conversationId, secondId);
      expect(state.messages, isEmpty);
      expect(state.isStreaming, isFalse);
      expect(
        (await h.repository.messagesFor(secondId))
            .where((m) => m.role == MessageRole.assistant),
        isEmpty,
        reason: 'the late reply must not be written into the new conversation',
      );
      expect(
        (await h.repository.messagesFor(firstId))
            .where((m) => m.role == MessageRole.assistant),
        isEmpty,
        reason: 'switching cancels the stream outright, so the abandoned '
            'answer is dropped rather than half-persisted',
      );
      expect(
        (await h.repository.messagesFor(firstId))
            .where((m) => m.role == MessageRole.user),
        hasLength(1),
        reason: 'the question the user actually sent is still on record',
      );
    });

    test('twenty rapid switches leave a coherent single selection', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      for (var i = 0; i < 20; i++) {
        await _seedConversation(h.repository, 'c$i', userText: 'q$i');
      }

      final pending = <Future<void>>[];
      for (var i = 0; i < 20; i++) {
        pending.add(controller.openConversation('c$i'));
      }
      // Kept unawaited on purpose — the storm is the point — but the futures
      // must still settle inside the test's lifetime.
      await Future.wait(pending);

      final state = h.stateOf(container);
      // Whatever won, the transcript must belong to exactly one conversation.
      final sources =
          state.messages.map((m) => m.sourceText).whereType<String>().toSet();
      expect(sources.length, lessThanOrEqualTo(1));
      if (state.conversationId.startsWith('c')) {
        expect(
          state.messages,
          await h.repository.messagesFor(state.conversationId),
        );
      }
      expect(state.error, isNull);
    });
  });

  group('regenerate', () {
    test('replaces the answer without duplicating the user turn', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final id = h.stateOf(container).conversationId;

      await h.send(container, 'one question');
      expect(
        (await h.repository.messagesFor(id))
            .where((m) => m.role == MessageRole.user),
        hasLength(1),
      );

      await h.regenerate(container);

      final state = h.stateOf(container);
      expect(
        state.messages.where((m) => m.role == MessageRole.user),
        hasLength(1),
      );
      final persisted = await h.repository.messagesFor(id);
      expect(persisted.where((m) => m.role == MessageRole.user), hasLength(1));
      expect(persisted.where((m) => m.role == MessageRole.assistant),
          hasLength(1));
    });

    test('clears a failed turn instead of stacking a second error', () async {
      final h = _Harness(manualProvider: true);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final id = h.stateOf(container).conversationId;

      await controller.send('will fail');
      await h.waitForRequest();
      h.provider.failLast(const LlmError(LlmErrorKind.network, 'boom'));
      await h.settle(container);
      expect(
        h.stateOf(container).messages.where((m) => m.role == MessageRole.error),
        hasLength(1),
      );

      await controller.regenerateLast();
      await h.waitForRequest(count: 2);
      h.provider.completeLast();
      await h.settle(container);

      final state = h.stateOf(container);
      expect(state.messages.where((m) => m.role == MessageRole.error), isEmpty);
      expect(state.messages.where((m) => m.role == MessageRole.assistant),
          hasLength(1));
      expect(
        (await h.repository.messagesFor(id))
            .where((m) => m.role == MessageRole.error),
        isEmpty,
      );
    });

    test('does nothing when there is no user turn to regenerate', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      await h.regenerate(container);

      expect(h.provider.requests, isEmpty);
      expect(h.stateOf(container).messages, isEmpty);
    });
  });

  group('stopGeneration', () {
    test('settles the bubble and keeps the transcript consistent', () async {
      final h = _Harness(manualProvider: true);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      await controller.send('stop me');
      await h.waitForRequest();
      expect(h.stateOf(container).isStreaming, isTrue);
      await controller.stopGeneration();
      await h.settle(container);
      final state = h.stateOf(container);
      expect(state.isStreaming, isFalse);
      expect(state.streamingMessageId, isNull);
      // The placeholder carried no answer, so it is dropped entirely rather
      // than left as an empty bubble that disappears after a restart.
      expect(state.messages.where((m) => m.role == MessageRole.assistant),
          isEmpty);
    });

    test('a cancelled turn is persisted as cancelled, never as completed',
        () async {
      final h = _Harness(manualProvider: true);
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      final id = h.stateOf(container).conversationId;

      // First turn completes normally so the row exists.
      await controller.send('first');
      await h.waitForRequest();
      h.provider.completeLast();
      await h.settle(container);

      // Second turn: emit a delta, then stop mid-stream.
      await controller.send('second');
      await h.waitForRequest(count: 2);
      h.provider.turns.last.emitDelta('It is snowing');
      await Future<void>.delayed(Duration.zero);
      await controller.stopGeneration();
      await h.settle(container);
      final persisted = await h.repository.messagesFor(id);
      expect(persisted.every((m) => m.status != ChatMessageStatus.streaming),
          isTrue);
      final inMemory = h.stateOf(container).messages;
      expect(
        inMemory.map((m) => m.status),
        isNot(contains(ChatMessageStatus.streaming)),
      );
    });
  });

  group('deletion', () {
    test('deleting the open conversation starts a blank draft', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await _seedConversation(h.repository, 'c1');
      await controller.openConversation('c1');

      await controller.handleConversationDeleted('c1');

      final state = h.stateOf(container);
      expect(state.isDraft, isTrue);
      expect(state.messages, isEmpty);
      expect(state.conversationId, isNot('c1'));
    });

    test('deleting another conversation leaves the page untouched', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await _seedConversation(h.repository, 'c1');
      await _seedConversation(h.repository, 'c2');
      await controller.openConversation('c1');
      final before = h.stateOf(container);

      await controller.handleConversationDeleted('c2');

      final after = h.stateOf(container);
      expect(after.conversationId, before.conversationId);
      expect(after.messages.length, before.messages.length);
      expect(after.epoch, before.epoch);
    });

    test('a deleted conversation cannot be resurrected by the next send',
        () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await _seedConversation(h.repository, 'c1');
      await controller.openConversation('c1');

      await h.repository.deleteConversation('c1');
      await controller.handleConversationDeleted('c1');
      await h.send(container, 'after delete');

      expect(await h.repository.getConversation('c1'), isNull);
      final live = h.repository.recentConversations();
      expect(await live, hasLength(1));
      expect((await live).single.id, h.stateOf(container).conversationId);
    });
  });

  group('conversation language', () {
    test('new conversation starts from the global default', () async {
      final h = _Harness(globalLanguage: CoachLanguage.french);
      final container = h.build();
      await h.controllerOf(container).initialize();
      expect(h.stateOf(container).conversationLanguage, CoachLanguage.french);
    });

    test('opening an old conversation restores its own target language',
        () async {
      final h = _Harness(globalLanguage: CoachLanguage.english);
      final container = h.build();
      await _seedConversation(h.repository, 'c1',
          language: CoachLanguage.korean, userText: '안녕', answer: '안녕하세요');
      await h.controllerOf(container).openConversation('c1');

      expect(
        h.stateOf(container).conversationLanguage,
        CoachLanguage.korean,
      );
      // The global default is untouched by a per-conversation restore.
      expect(container.read(settingsControllerProvider).preferredLanguage,
          CoachLanguage.english);
    });

    test('switching the conversation language persists on the row', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();
      await h.send(container, 'seed it');
      final id = h.stateOf(container).conversationId;

      await controller.setConversationLanguage(CoachLanguage.german);

      expect(h.stateOf(container).conversationLanguage, CoachLanguage.german);
      expect((await h.repository.getConversation(id))?.targetLanguage,
          CoachLanguage.german);
      expect(container.read(settingsControllerProvider).preferredLanguage,
          CoachLanguage.english,
          reason: 'the in-chat selector must not rewrite the global default');
    });
  });

  group('history refresh', () {
    test('saving a message refreshes the history list', () async {
      final h = _Harness();
      final container = h.build();
      final controller = h.controllerOf(container);
      await controller.initialize();

      final history = container.read(historyControllerProvider.future);
      expect(await history, isEmpty);

      await h.send(container, 'seed the history');

      final refreshed = await container.read(historyControllerProvider.future);
      expect(refreshed, hasLength(1));
      expect(refreshed.single.preview, 'seed the history');
      expect(refreshed.single.title, 'seed the history');
    });
  });
}

/// Wraps the in-memory repository and can hold the next load open. Models a
/// slow disk round trip for conversation A that lands *after* the user already
/// switched to B — the classic stale-load overwrite.
class _GatedRepository implements ConversationRepository {
  _GatedRepository(this._delegate);

  final InMemoryConversationRepository _delegate;
  Completer<void>? _gate;

  void armNextLoad() => _gate = Completer<void>();

  void release() {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  Future<T> _hold<T>(Future<T> Function() run) async {
    final gate = _gate;
    if (gate == null) return run();
    _gate = null;
    await gate.future;
    return run();
  }

  @override
  Future<Conversation?> getConversation(String id) =>
      _hold(() => _delegate.getConversation(id));

  @override
  Future<List<ChatMessage>> messagesFor(String id) =>
      _hold(() => _delegate.messagesFor(id));

  @override
  Future<void> ensureConversation(
    String id, {
    String? title,
    CoachLanguage? preferredLanguage,
    CoachLanguage? targetLanguage,
    DateTime? createdAt,
  }) =>
      _delegate.ensureConversation(
        id,
        title: title,
        preferredLanguage: preferredLanguage,
        targetLanguage: targetLanguage,
        createdAt: createdAt,
      );

  @override
  Future<void> updateTitle(String conversationId, String title) =>
      _delegate.updateTitle(conversationId, title);

  @override
  Future<String> appendMessage({
    required String conversationId,
    required ChatMessage message,
  }) =>
      _delegate.appendMessage(
        conversationId: conversationId,
        message: message,
      );

  @override
  Future<void> replaceAssistantTurn({
    required String conversationId,
    required String userMessageId,
    required ChatMessage assistant,
  }) =>
      _delegate.replaceAssistantTurn(
        conversationId: conversationId,
        userMessageId: userMessageId,
        assistant: assistant,
      );

  @override
  Future<void> updateConversationLanguage(
    String conversationId,
    CoachLanguage language,
  ) =>
      _delegate.updateConversationLanguage(conversationId, language);

  @override
  Future<void> deleteConversation(String conversationId) =>
      _delegate.deleteConversation(conversationId);

  @override
  Future<void> deleteAllConversations() => _delegate.deleteAllConversations();

  @override
  Future<List<({String id, String preview, DateTime updatedAt})>>
      recentConversations({int limit = 50, String? query}) =>
          _delegate.recentConversations(limit: limit, query: query);
}
