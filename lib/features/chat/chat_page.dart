import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/ai/llm_event.dart';
import '../../core/audio/asr_engine.dart';
import '../../core/database/app_database_provider.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/chat_models.dart';
import '../../core/network/api_client.dart';
import '../../core/repositories/sqlite_conversation_repository.dart';
import '../../core/ui/app_toast.dart';
import '../history/application/history_controller.dart';
import '../settings/application/settings_controller.dart';
import 'application/chat_session_state.dart';
import 'application/conversation_providers.dart';
import 'application/speech_session_controller.dart';
import 'application/waveform_controller.dart';
import 'widgets/message_bubble.dart';
import 'widgets/session_character.dart';
import 'widgets/session_error_card.dart';
import 'widgets/waveform_view.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, this.initialPrompt});

  final String? initialPrompt;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final controller = TextEditingController();
  final scrollController = ScrollController();
  final messages = <ChatMessage>[];
  final _uuid = const Uuid();
  StreamSubscription<LlmEvent>? replySubscription;
  bool isStreaming = false;
  bool _atBottom = true;
  String _currentConversationId = '';
  String _lastUserInput = '';
  bool _hydrated = false;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrate());
    _applyInitialPrompt(widget.initialPrompt);
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialPrompt != widget.initialPrompt) {
      _applyInitialPrompt(widget.initialPrompt);
    }
  }

  void _applyInitialPrompt(String? prompt) {
    final value = prompt?.trim();
    if (value == null || value.isEmpty) return;
    controller
      ..text = value
      ..selection = TextSelection.collapsed(offset: value.length);
  }

  void _onScroll() {
    if (!scrollController.hasClients) return;
    final pos = scrollController.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 24;
    if (atBottom != _atBottom) {
      setState(() => _atBottom = atBottom);
    }
  }

  Future<void> _hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    final repo = ref.read(conversationRepositoryProvider);
    final settings = ref.read(settingsControllerProvider);
    if (settings.saveHistory &&
        settings.lastConversationId != null &&
        settings.lastConversationId!.isNotEmpty) {
      final id = settings.lastConversationId!;
      final msgs = await repo.messagesFor(id);
      if (!mounted) return;
      setState(() {
        _currentConversationId = id;
        messages
          ..clear()
          ..addAll(msgs);
      });
    } else {
      _currentConversationId = _uuid.v4();
    }
  }

  @override
  void dispose() {
    replySubscription?.cancel();
    scrollController.removeListener(_onScroll);
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  Future<void> toggleListening() async {
    final controller = ref.read(speechSessionControllerProvider.notifier);
    final state = ref.read(speechSessionControllerProvider);
    if (state.listening) {
      await controller.stop();
      return;
    }
    // Surface a friendly error if the runtime hasn't loaded a profile yet
    // — the controller would also fail, but with a less actionable message.
    final ready = await controller.ensureEngineReady();
    if (!ready) {
      _showVoiceError('当前设备没有可用的语音识别服务');
      return;
    }
    try {
      await controller.start();
    } on PlatformException catch (error) {
      _showVoiceError(error.message ?? '无法启动语音识别');
    }
  }

  String _describeAsrError(
    AsrErrorKind kind, {
    String? nativeMessage,
  }) {
    switch (kind) {
      case AsrErrorKind.permissionDenied:
        return '麦克风权限被拒绝';
      case AsrErrorKind.busy:
        return '识别器正忙，请稍后再试';
      case AsrErrorKind.modelMissing:
        return '语音模型未安装，请前往设置页下载';
      case AsrErrorKind.timeout:
        return '识别超时，请重试';
      case AsrErrorKind.unavailable:
        return '当前设备没有可用的语音识别服务';
      case AsrErrorKind.format:
        return '识别结果解析失败';
      case AsrErrorKind.unknown:
        final detail = nativeMessage?.trim();
        return detail == null || detail.isEmpty ? '语音识别失败' : '语音识别失败：$detail';
    }
  }

  void _showVoiceError(String message) {
    if (!mounted) return;
    AppToast.error(context, message);
  }

  Future<void> send() async {
    if (isStreaming) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;
    controller.clear();
    _lastUserInput = text;

    if (_currentConversationId.isEmpty) {
      _currentConversationId = _uuid.v4();
    }

    final settings = ref.read(settingsControllerProvider);
    final userMsg = ChatMessage(
      id: 'u_${_uuid.v4()}',
      role: MessageRole.user,
      sourceText: text,
      createdAt: DateTime.now(),
    );
    final placeholder = ChatMessage(
      id: 'a_${_uuid.v4()}',
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
    );
    setState(() {
      messages
        ..add(userMsg)
        ..add(placeholder);
      isStreaming = true;
    });
    _scrollDown();

    if (settings.saveHistory) {
      await _saveSettingsAndMessages(userMsg);
    }
    _beginReply(text, placeholder.id);
  }

  Future<void> _saveSettingsAndMessages(ChatMessage userMsg) async {
    final repo = ref.read(conversationRepositoryProvider);
    final settings = ref.read(settingsControllerProvider);
    await repo.ensureConversation(
      _currentConversationId,
      preferredLanguage: settings.preferredLanguage,
      targetLanguage: settings.preferredLanguage,
    );
    await repo.appendMessage(
      conversationId: _currentConversationId,
      message: userMsg,
    );
    if (settings.lastConversationId != _currentConversationId) {
      ref
          .read(settingsControllerProvider.notifier)
          .setLastConversationId(_currentConversationId);
    }
  }

  void _beginReply(String text, String placeholderId) {
    replySubscription?.cancel();
    final engine = ref.read(conversationEngineProvider);
    final settings = ref.read(settingsControllerProvider);
    final historyContext =
        settings.saveHistory ? _recentContext() : const <ChatMessage>[];
    replySubscription =
        engine.replyStream(text, context: historyContext).listen(
      (event) {
        if (!mounted) return;
        switch (event) {
          case LlmEventDelta(:final text):
            _appendDelta(placeholderId, text);
          case LlmEventThinking(:final text):
            _appendThinking(placeholderId, text);
          case LlmEventComplete(:final response, :final assistantMessage):
            _finalizeMessage(placeholderId, assistantMessage);
            _persistAssistant(assistantMessage.copyWith(response: response));
          case LlmEventError(:final error):
            _renderError(placeholderId, error);
        }
      },
      onError: (Object e) {
        if (!mounted) return;
        _renderError(
            placeholderId, LlmError(LlmErrorKind.unknown, e.toString()));
      },
      onDone: () {
        if (!mounted) return;
        setState(() => isStreaming = false);
        _scrollDown();
      },
    );
  }

  List<ChatMessage> _recentContext({int max = 20}) {
    if (messages.length <= max) return List.unmodifiable(messages);
    return List.unmodifiable(messages.sublist(messages.length - max));
  }

  Future<void> _persistAssistant(ChatMessage assistant) async {
    final settings = ref.read(settingsControllerProvider);
    if (!settings.saveHistory) return;
    final repo = ref.read(conversationRepositoryProvider);
    final id = _currentConversationId;
    if (id.isEmpty) return;
    await repo.ensureConversation(id);
    await repo.appendMessage(conversationId: id, message: assistant);

    // Auto-title from the first user input — cheap local heuristic.
    final repo0 = repo;
    if (repo0 is SqliteConversationRepository) {
      final meta = await repo0.findById(id);
      if (meta != null &&
          meta.title.startsWith('对话 ') &&
          _lastUserInput.isNotEmpty) {
        await repo0.updateTitle(id, _shortTitle(_lastUserInput));
      }
    }
  }

  void _appendDelta(String id, String delta) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final current = messages[idx];
    final response = current.response ??
        CoachResponse(
          intent: CoachIntent.conversation,
          sourceLanguage: 'auto',
          targetLanguage: '',
          primary: '',
          explanation: '',
          sentences: const <CoachSentence>[],
        );
    final next = response.copyWith(primary: response.primary + delta);
    setState(() {
      messages[idx] = current.copyWith(response: next);
    });
  }

  void _appendThinking(String id, String delta) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    final current = messages[idx];
    final response = current.response ??
        CoachResponse(
          intent: CoachIntent.conversation,
          sourceLanguage: 'auto',
          targetLanguage: '',
          primary: '',
          explanation: '',
          sentences: const <CoachSentence>[],
        );
    final next = response.copyWith(thinking: response.thinking + delta);
    setState(() {
      messages[idx] = current.copyWith(response: next);
    });
  }

  void _finalizeMessage(String id, ChatMessage finalized) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    setState(() {
      messages[idx] = finalized.copyWith(id: id);
    });
  }

  void _renderError(String id, LlmError error) {
    final idx = messages.indexWhere((m) => m.id == id);
    if (idx < 0) return;
    setState(() {
      messages[idx] = ChatMessage(
        id: id,
        role: MessageRole.error,
        createdAt: DateTime.now(),
        sourceText: _describe(error),
      );
    });
  }

  void stopReply() {
    replySubscription?.cancel();
    replySubscription = null;
    if (!mounted) return;
    setState(() => isStreaming = false);
    _scrollDown();
  }

  void retryLast() {
    if (_lastUserInput.isEmpty || isStreaming) return;
    controller.text = _lastUserInput;
    send();
  }

  String _describe(LlmError error) {
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

  String _shortTitle(String sourceText) {
    final trimmed = sourceText.trim();
    if (trimmed.length <= 18) return trimmed;
    return '${trimmed.substring(0, 18)}…';
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _useSuggestion(String text) {
    controller.text = text;
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);
    send();
  }

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(chatSessionPhaseProvider);
    final error = ref.watch(chatSessionErrorProvider);
    final speechState = ref.watch(speechSessionControllerProvider);
    // Mirror partial transcripts into the composer + surface engine errors
    // as toasts. Runs in build() so the listener stays attached for the
    // whole widget lifetime, not just on hot reloads of the listener.
    ref.listen<SpeechSessionState>(speechSessionControllerProvider,
        (prev, next) {
      if (!mounted) return;
      if (next.partialText != prev?.partialText) {
        controller.text = next.partialText;
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);
      }
      if (next.lastError != null && prev?.lastError != next.lastError) {
        _showVoiceError(
          _describeAsrError(
            next.lastError!,
            nativeMessage: next.lastErrorMessage,
          ),
        );
      }
    });
    return Scaffold(
      drawer: const _ChatDrawer(),
      onDrawerChanged: (opened) {
        if (!opened) setState(() {});
      },
      appBar: const _ChatAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? _EmptyState(
                      onPickSuggestion: _useSuggestion,
                    )
                  : Stack(
                      children: [
                        ListView.builder(
                          controller: scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
                          itemCount: messages.length,
                          itemBuilder: (context, index) {
                            final message = messages[index];
                            if (message.role == MessageRole.error) {
                              return _ErrorBubble(
                                text: message.sourceText ?? '',
                                onRetry:
                                    _lastUserInput.isEmpty ? null : retryLast,
                              );
                            }
                            final isLast = index == messages.length - 1;
                            return MessageBubble(
                              message: message,
                              conversationId: _currentConversationId,
                              isLast: isLast,
                              isStreaming: isStreaming,
                              onRegenerate: (!isStreaming &&
                                      _lastUserInput.isNotEmpty &&
                                      message.role == MessageRole.assistant)
                                  ? retryLast
                                  : null,
                            );
                          },
                        ),
                        if (!_atBottom)
                          Positioned(
                            right: 16,
                            bottom: 12,
                            child: _ScrollToBottomButton(
                              hasNew: isStreaming,
                              onTap: _scrollDown,
                            ),
                          ),
                      ],
                    ),
            ),
            _SessionStatusStrip(
              phase: phase,
              error: error,
            ),
            if (isStreaming) _StopGenerationBar(onStop: stopReply),
            _Composer(
              controller: controller,
              onSend: send,
              onToggleListening: toggleListening,
              onStop: isStreaming ? stopReply : null,
              isListening: speechState.listening,
            ),
          ],
        ),
      ),
    );
  }
}

/// Top AppBar mirroring the ChatGPT / Doubao pattern: hamburger to open
/// the conversation drawer on the left, model selector + language selector
/// on the right, app title centred. Tapping a selector opens a popup so
/// the user never has to leave the chat to switch context.
class _ChatAppBar extends ConsumerWidget implements PreferredSizeWidget {
  const _ChatAppBar();

  static const _titleStyle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
  );

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    return AppBar(
      elevation: 0,
      scrolledUnderElevation: 0.5,
      backgroundColor: Theme.of(context).colorScheme.surface,
      leading: Builder(
        builder: (ctx) => IconButton(
          tooltip: '对话列表',
          icon: const Icon(Icons.menu_rounded),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        ),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Language Coach', style: _titleStyle),
          const SizedBox(width: 8),
          _ModelSelector(provider: settings.provider),
        ],
      ),
      centerTitle: false,
      titleSpacing: 0,
      actions: [
        _LanguageSelector(
          current: settings.preferredLanguage,
          onPick: (lang) => ref
              .read(settingsControllerProvider.notifier)
              .setPreferredLanguage(lang),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _ModelSelector extends ConsumerWidget {
  const _ModelSelector({required this.provider});

  final AiProvider provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return PopupMenuButton<AiProvider>(
      tooltip: '切换模型',
      position: PopupMenuPosition.under,
      itemBuilder: (ctx) => AiProvider.values
          .map(
            (p) => PopupMenuItem<AiProvider>(
              value: p,
              child: Row(
                children: [
                  Icon(
                    _iconFor(p),
                    size: 16,
                    color: p == provider ? scheme.primary : Colors.black54,
                  ),
                  const SizedBox(width: 8),
                  Text(_labelFor(p)),
                ],
              ),
            ),
          )
          .toList(),
      onSelected: (p) =>
          ref.read(settingsControllerProvider.notifier).setProvider(p),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_labelFor(provider),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                )),
            const SizedBox(width: 2),
            const Icon(Icons.arrow_drop_down, size: 14),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(AiProvider p) => switch (p) {
        AiProvider.auto => Icons.auto_awesome,
        AiProvider.miniMax => Icons.bolt_outlined,
        AiProvider.deepSeek => Icons.psychology_outlined,
        AiProvider.localQwen => Icons.memory_outlined,
      };

  String _labelFor(AiProvider p) => switch (p) {
        AiProvider.auto => 'Auto',
        AiProvider.miniMax => 'MiniMax',
        AiProvider.deepSeek => 'DeepSeek',
        AiProvider.localQwen => 'Qwen3 本地',
      };
}

class _LanguageSelector extends StatelessWidget {
  const _LanguageSelector({required this.current, required this.onPick});

  final CoachLanguage current;
  final ValueChanged<CoachLanguage> onPick;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<CoachLanguage>(
      tooltip: '切换目标语言',
      position: PopupMenuPosition.under,
      itemBuilder: (ctx) => CoachLanguage.values
          .map(
            (l) => PopupMenuItem<CoachLanguage>(
              value: l,
              child: Row(
                children: [
                  Text(l.flag),
                  const SizedBox(width: 8),
                  Text(
                    l.label,
                    style: TextStyle(
                      fontWeight:
                          l == current ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
      onSelected: onPick,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        child: Text(
          '${current.flag} ${current.label}',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onPickSuggestion});

  final ValueChanged<String> onPickSuggestion;

  /// Curated starter prompts. Three buckets — translation, roleplay,
  /// correction — chosen so the empty state surfaces the app's headline
  /// features without overwhelming new users.
  static const _suggestions = <String>[
    '今天下雨，用英语怎么表达？',
    '帮我用英语模拟一段餐厅点餐对话',
    '请纠正我：I am go to school yesterday',
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.record_voice_over_rounded,
                size: 42,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              '今天想练习什么？',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '选一个试试，或直接输入',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 22),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: _suggestions
                  .map(
                    (text) => ActionChip(
                      avatar: const Icon(Icons.bolt_outlined, size: 16),
                      label: Text(text),
                      onPressed: () => onPickSuggestion(text),
                      backgroundColor: scheme.surface,
                      side: BorderSide(color: Colors.black12),
                      labelStyle: const TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Floating button shown when the user scrolls up away from the latest
/// reply. The badge dot surfaces that more tokens have arrived while the
/// user was reading — same affordance as ChatGPT / Doubao / Claude.
class _ScrollToBottomButton extends StatelessWidget {
  const _ScrollToBottomButton({
    required this.hasNew,
    required this.onTap,
  });

  final bool hasNew;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      elevation: 4,
      shadowColor: Colors.black26,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(
                Icons.arrow_downward_rounded,
                size: 20,
                color: scheme.onPrimary,
              ),
              if (hasNew)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: scheme.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: scheme.surface, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onToggleListening,
    required this.onStop,
    required this.isListening,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onToggleListening;
  final VoidCallback? onStop;
  final bool isListening;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  /// Show the character counter only when the input starts to look long —
  /// community convention is to keep the bottom bar quiet unless the user
  /// is actively composing a multi-line message.
  static const _counterThreshold = 160;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final scheme = Theme.of(context).colorScheme;
    final text = controller.text;
    final showCounter = text.characters.length >= _counterThreshold;
    final overLimit = text.characters.length > 500;

    return Material(
      color: scheme.surface,
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.black12),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    onPressed: widget.onToggleListening,
                    icon: Icon(widget.isListening
                        ? Icons.stop_circle
                        : Icons.mic_none),
                    color: widget.isListening ? scheme.error : null,
                    tooltip: widget.isListening ? '停止识别' : '语音输入',
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 6,
                        textInputAction: TextInputAction.send,
                        keyboardType: TextInputType.multiline,
                        onSubmitted: (_) => widget.onSend(),
                        decoration: const InputDecoration(
                          hintText: '输入你想学习的表达…',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  if (widget.onStop != null)
                    IconButton(
                      onPressed: widget.onStop,
                      icon: const Icon(Icons.stop_circle_outlined),
                      tooltip: '停止生成',
                    )
                  else
                    IconButton.filled(
                      onPressed: widget.onSend,
                      icon: const Icon(Icons.arrow_upward_rounded),
                      tooltip: '发送',
                    ),
                ],
              ),
            ),
            if (showCounter)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Text(
                  '${text.characters.length} / 500',
                  style: TextStyle(
                    fontSize: 10,
                    color: overLimit ? scheme.error : Colors.black45,
                    fontWeight: overLimit ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBubble extends StatelessWidget {
  const _ErrorBubble({required this.text, this.onRetry});
  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer))),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// Status strip above the composer — shows the placeholder character
/// during the recording/processing/playing phases, the live waveform
/// while ASR is producing samples, and a retry card when the session
/// has surfaced an error. Idle = nothing.
class _SessionStatusStrip extends ConsumerWidget {
  const _SessionStatusStrip({
    required this.phase,
    required this.error,
  });

  final ChatSessionPhase phase;
  final SessionError? error;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (error != null) {
      return SessionErrorCard(error: error!);
    }
    if (phase == ChatSessionPhase.recording) {
      // Reset the buffer on phase entry so the waveform only shows
      // samples from the active session.
      ref.listen<ChatSessionPhase>(chatSessionPhaseProvider, (prev, next) {
        if (prev == ChatSessionPhase.recording &&
            next != ChatSessionPhase.recording) {
          ref.read(waveformControllerProvider.notifier).reset();
        }
      });
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: [
            const SessionCharacter(phase: ChatSessionPhase.recording, size: 36),
            const SizedBox(width: 8),
            const Expanded(child: WaveformView()),
          ],
        ),
      );
    }
    if (phase == ChatSessionPhase.processing ||
        phase == ChatSessionPhase.playing) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: [
            SessionCharacter(phase: phase, size: 36),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _labelFor(phase),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }
    return const SizedBox.shrink();
  }

  String _labelFor(ChatSessionPhase phase) {
    switch (phase) {
      case ChatSessionPhase.processing:
        return '正在生成回复…';
      case ChatSessionPhase.playing:
        return '正在播放';
      case ChatSessionPhase.idle:
      case ChatSessionPhase.recording:
      case ChatSessionPhase.error:
        return '';
    }
  }
}

/// Slide-out conversation history. Reuses [historyControllerProvider] so the
/// drawer and the History tab see the exact same data — switching to an old
/// conversation just rewires `lastConversationId` and the chat page reloads.
class _ChatDrawer extends ConsumerWidget {
  const _ChatDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(historyControllerProvider);
    final settings = ref.read(settingsControllerProvider);
    final currentId = settings.lastConversationId;
    final scheme = Theme.of(context).colorScheme;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
              child: Row(
                children: [
                  Icon(Icons.forum_outlined, color: scheme.primary),
                  const SizedBox(width: 8),
                  const Text(
                    '对话',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '新建对话',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () {
                      ref
                          .read(settingsControllerProvider.notifier)
                          .setLastConversationId(null);
                      Navigator.of(context).pop();
                      AppToast.success(context, '已开始新对话');
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: conversations.when(
                data: (items) {
                  if (items.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '还没有保存的对话',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final selected = item.id == currentId;
                      return ListTile(
                        selected: selected,
                        selectedTileColor:
                            scheme.primaryContainer.withValues(alpha: 0.4),
                        leading: const Icon(Icons.chat_bubble_outline),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          item.preview.isEmpty ? '(无内容)' : item.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          ref
                              .read(settingsControllerProvider.notifier)
                              .setLastConversationId(item.id);
                          Navigator.of(context).pop();
                        },
                        onLongPress: () =>
                            _confirmDelete(context, ref, item.id),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败：$e')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String conversationId,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除该对话？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref
        .read(historyControllerProvider.notifier)
        .deleteConversation(conversationId);
  }
}

/// Floating "stop generating" pill that surfaces between the status strip
/// and the composer while the engine is emitting tokens. Doubao / ChatGPT
/// / Claude all use this affordance — a more discoverable target than the
/// composer's icon-only stop button, especially during long replies.
class _StopGenerationBar extends StatelessWidget {
  const _StopGenerationBar({required this.onStop});

  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Material(
        color: scheme.surfaceContainerHighest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        elevation: 0,
        child: InkWell(
          onTap: onStop,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  '正在生成',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.stop_circle_outlined, size: 16, color: scheme.error),
                const SizedBox(width: 4),
                const Text(
                  '停止',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
