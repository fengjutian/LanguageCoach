import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/asr_engine.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/chat_models.dart';
import '../../core/ui/app_toast.dart';
import '../history/application/history_controller.dart';
import '../settings/application/settings_controller.dart';
import 'application/chat_controller.dart';
import 'application/chat_session_state.dart';
import 'application/chat_state.dart';
import 'application/speech_session_controller.dart';
import 'application/tts_controller.dart';
import 'application/waveform_controller.dart';
import 'widgets/message_bubble.dart';
import 'widgets/session_character.dart';
import 'widgets/waveform_view.dart';

/// Renders the transcript for whatever conversation [chatControllerProvider]
/// currently owns. This widget deliberately holds no conversation id, no
/// message list and no stream subscription — everything it shows is read from
/// the controller, and every mutation is a command on it. The only state kept
/// here is genuinely view-local (text + scroll controllers).
class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key, this.initialPrompt});

  final String? initialPrompt;

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final controller = TextEditingController();
  final scrollController = ScrollController();
  bool _atBottom = true;

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(chatControllerProvider.notifier).initialize();
    });
    _applyInitialPrompt(widget.initialPrompt);
  }

  @override
  void didUpdateWidget(covariant ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialPrompt != widget.initialPrompt) {
      _applyInitialPrompt(widget.initialPrompt);
    }
  }

  @override
  void dispose() {
    scrollController.removeListener(_onScroll);
    controller.dispose();
    scrollController.dispose();
    super.dispose();
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

  Future<void> toggleListening() async {
    final speech = ref.read(speechSessionControllerProvider.notifier);
    final state = ref.read(speechSessionControllerProvider);
    if (state.listening) {
      await speech.stop();
      return;
    }
    // Surface a friendly error if the runtime hasn't loaded a profile yet
    // — the controller would also fail, but with a less actionable message.
    final ready = await speech.ensureEngineReady();
    if (!ready) {
      _showVoiceError('当前设备没有可用的语音识别服务');
      return;
    }
    try {
      await speech.start();
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

  void _send() {
    final text = controller.text.trim();
    if (text.isEmpty) return;
    if (text.characters.length > kMaxUserMessageLength) return;
    controller.clear();
    _scrollDown();
    unawaited(ref.read(chatControllerProvider.notifier).send(text));
  }

  void _useSuggestion(String text) {
    controller.text = text;
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);
    _send();
  }

  /// Stop playback and dictation when the conversation underneath them
  /// changes. Errors are swallowed on purpose: a missing audio backend must
  /// not block the conversation switch the user actually asked for.
  Future<void> _stopSessionAudio() async {
    try {
      await ref.read(ttsControllerProvider.notifier).stop();
    } catch (_) {
      // No audio backend available in this environment.
    }
    try {
      if (ref.read(speechSessionControllerProvider).listening) {
        await ref.read(speechSessionControllerProvider.notifier).stop();
      }
    } catch (_) {
      // Speech backend unavailable; nothing to stop.
    }
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

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final chatController = ref.read(chatControllerProvider.notifier);
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

    // A conversation switch (new / open / deleted) means the transcript the
    // user was reading is gone. The draft input travels with the
    // conversation, and audio / dictation belong to the session that just
    // ended — leaving either running would talk over a conversation the user
    // is no longer looking at.
    ref.listen<ChatState>(chatControllerProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        AppToast.error(context, next.error!);
      }
      final previousErrorIds = prev?.messages
              .where((message) => message.role == MessageRole.error)
              .map((message) => message.id)
              .toSet() ??
          const <String>{};
      for (final message in next.messages.where(
        (message) =>
            message.role == MessageRole.error &&
            !previousErrorIds.contains(message.id),
      )) {
        final text = message.sourceText?.trim();
        if (text != null && text.isNotEmpty) AppToast.error(context, text);
      }
      if (prev == null || prev.epoch == next.epoch) return;
      if (controller.text.trim().isNotEmpty) controller.clear();
      setState(() => _atBottom = true);
      _scrollDown();
      unawaited(_stopSessionAudio());
    });

    ref.listen<TtsPlaybackState>(ttsControllerProvider, (prev, next) {
      final error = next.lastError;
      if (error != null && !identical(error, prev?.lastError)) {
        AppToast.error(context, error.message);
      }
    });

    final messages = chat.messages
        .where((message) => message.role != MessageRole.error)
        .toList(growable: false);
    final turnLanguageLabel = chat.lastTurnLanguage?.label;

    return Scaffold(
      drawer: const _ChatDrawer(),
      appBar: const _ChatAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            if (turnLanguageLabel != null &&
                chat.lastTurnLanguage != null &&
                chat.lastTurnLanguage != chat.conversationLanguage)
              _ExplicitLanguageNotice(language: chat.lastTurnLanguage!),
            if (chat.loadStatus == ChatLoadStatus.loading)
              const LinearProgressIndicator(minHeight: 2),
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
                            final isStreamingBubble = chat.isStreaming &&
                                index == messages.length - 1;
                            final isLast = index == messages.length - 1;
                            return MessageBubble(
                              message: message,
                              conversationId: chat.conversationId,
                              isLast: isLast,
                              isStreaming: isStreamingBubble,
                              onRegenerate: (!chat.isStreaming &&
                                      chat.lastUserMessageId != null &&
                                      message.role == MessageRole.assistant)
                                  ? chatController.regenerateLast
                                  : null,
                            );
                          },
                        ),
                        if (!_atBottom)
                          Positioned(
                            right: 16,
                            bottom: 12,
                            child: _ScrollToBottomButton(
                              hasNew: chat.isStreaming,
                              onTap: _scrollDown,
                            ),
                          ),
                      ],
                    ),
            ),
            const _SessionStatusStripHost(),
            if (chat.isStreaming)
              _StopGenerationBar(onStop: chatController.stopGeneration),
            _Composer(
              controller: controller,
              onSend: _send,
              onToggleListening: toggleListening,
              onStop: chat.isStreaming ? chatController.stopGeneration : null,
              isListening: speechState.listening,
              maxLength: kMaxUserMessageLength,
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
    final conversationLanguage =
        ref.watch(chatControllerProvider.select((s) => s.conversationLanguage));
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
        // The in-chat selector is the *conversation* target, not the global
        // default. Changing it here used to silently rewrite the user's
        // app-wide default and confuse every other conversation.
        _LanguageSelector(
          current: conversationLanguage,
          onPick: (lang) => ref
              .read(chatControllerProvider.notifier)
              .setConversationLanguage(lang),
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
      tooltip: '切换本轮目标语言',
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

/// Shown when the learner's own words named a language that differs from the
/// conversation selector, so an explicit "用英语怎么说" doesn't look like the
/// selector was ignored by mistake.
class _ExplicitLanguageNotice extends StatelessWidget {
  const _ExplicitLanguageNotice({required this.language});

  final CoachLanguage language;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Text(
        '本轮已按你的要求使用 ${language.flag} ${language.label} 回答',
        style: TextStyle(
          fontSize: 12,
          color: scheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
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
    required this.maxLength,
  });
  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onToggleListening;
  final VoidCallback? onStop;
  final bool isListening;
  final int maxLength;

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
  void didUpdateWidget(covariant _Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
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
    final length = text.characters.length;
    final showCounter = length >= _counterThreshold;
    final overLimit = length > widget.maxLength;

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
                        onSubmitted: overLimit ? null : (_) => widget.onSend(),
                        decoration: InputDecoration(
                          hintText: overLimit
                              ? '内容超出 ${widget.maxLength} 字上限，请精简后再发送'
                              : '输入你想学习的表达…',
                          hintStyle:
                              overLimit ? TextStyle(color: scheme.error) : null,
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
                      // Hard block instead of a red counter: a message the
                      // server will reject should never leave the device.
                      onPressed: overLimit ? null : widget.onSend,
                      icon: const Icon(Icons.arrow_upward_rounded),
                      tooltip: overLimit ? '超出字数上限' : '发送',
                    ),
                ],
              ),
            ),
            if (showCounter)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 4),
                child: Text(
                  '$length / ${widget.maxLength}',
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

/// Status strip above the composer — shows the placeholder character
/// during the recording/processing/playing phases, the live waveform
/// while ASR is producing samples, and a retry card when the session
/// has surfaced an error. Idle = nothing.
class _SessionStatusStripHost extends ConsumerWidget {
  const _SessionStatusStripHost();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _SessionStatusStrip(
      phase: ref.watch(chatSessionPhaseProvider),
    );
  }
}

class _SessionStatusStrip extends ConsumerWidget {
  const _SessionStatusStrip({
    required this.phase,
  });

  final ChatSessionPhase phase;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

/// Slide-out conversation history. Shares [historyControllerProvider] with the
/// History tab, and delegates selection to the same
/// `ChatController.openConversation` — the drawer used to only rewrite
/// `lastConversationId`, so tapping a conversation appeared to do nothing.
class _ChatDrawer extends ConsumerWidget {
  const _ChatDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversations = ref.watch(historyControllerProvider);
    final currentId = ref.watch(chatControllerProvider).conversationId;
    final scheme = Theme.of(context).colorScheme;

    ref.listen(historyControllerProvider, (prev, next) {
      if (next.hasError && next.error != prev?.error) {
        AppToast.error(context, '加载对话失败：${next.error}');
      }
    });

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
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await ref
                          .read(chatControllerProvider.notifier)
                          .newConversation();
                      if (!context.mounted) return;
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
                        onTap: () async {
                          Navigator.of(context).pop();
                          await ref
                              .read(chatControllerProvider.notifier)
                              .openConversation(item.id);
                        },
                        onLongPress: () =>
                            _confirmDelete(context, ref, item.id),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => const SizedBox.shrink(),
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
    await deleteConversationAndSync(ref, conversationId);
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
