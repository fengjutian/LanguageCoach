import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_player.dart';
import '../../../core/models/chat_models.dart';
import '../../settings/application/settings_controller.dart';
import '../application/tts_controller.dart';

/// Quick check for inline / block-level markdown markers. We don't try to be
/// exhaustive — anything that *might* be markdown routes through [MarkdownBody]
/// so we don't surface raw `**`/`[]()` to users. Plain prose stays on a `Text`
/// widget, which keeps the existing `find.text(...)` widget tests stable.
bool _looksLikeMarkdown(String text) {
  if (text.isEmpty) return false;
  return RegExp(
    r'(\*\*|\*|`|~~|\[.+\]\(.+\)|^#{1,6}\s|^\s*[-+*]\s|^\s*\d+\.\s|^\s*>|\n\n)',
    multiLine: true,
  ).hasMatch(text);
}

bool _containsChinese(String text) =>
    RegExp(r'[\u3400-\u4DBF\u4E00-\u9FFF]').hasMatch(text);

String _languageLabel(String code) {
  if (code.startsWith('zh')) return '中文原文';
  if (code.startsWith('en')) return '英文表达';
  return '目标表达';
}

/// Renders [text] as plain text most of the time, but switches to a markdown
/// pipeline whenever the content looks like markdown. Styles inherit from the
/// caller-supplied [style] so headings / bold / italic all keep the same base
/// typography as the surrounding bubble.
class _BubbleText extends StatelessWidget {
  const _BubbleText({required this.text, this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    if (!_looksLikeMarkdown(text)) {
      return Text(text, style: base);
    }
    final muted = base.color ?? Colors.black87;
    final sheet = MarkdownStyleSheet(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      del: base.copyWith(decoration: TextDecoration.lineThrough),
      h1: base.copyWith(
          fontSize: (base.fontSize ?? 14) * 1.6, fontWeight: FontWeight.w700),
      h2: base.copyWith(
          fontSize: (base.fontSize ?? 14) * 1.4, fontWeight: FontWeight.w700),
      h3: base.copyWith(
          fontSize: (base.fontSize ?? 14) * 1.2, fontWeight: FontWeight.w700),
      code: base.copyWith(
        fontFamily: 'monospace',
        backgroundColor: Colors.black12,
      ),
      codeblockDecoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(6),
      ),
      codeblockPadding: const EdgeInsets.all(8),
      blockquote: base.copyWith(color: muted.withValues(alpha: 0.7)),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: Colors.black26, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.black12, width: 1)),
      ),
    );
    return MarkdownBody(
      data: text,
      styleSheet: sheet,
      shrinkWrap: true,
      fitContent: true,
    );
  }
}

/// Speech-speed stops mirrored from the settings page so the bubble on every
/// message stays in lock-step with the chosen value.
const _kBubbleSpeedStops = <double>[0.75, 0.85, 1.0, 1.15, 1.25, 1.5];

class MessageBubble extends ConsumerWidget {
  const MessageBubble({
    required this.message,
    required this.conversationId,
    this.isLast = false,
    this.isStreaming = false,
    this.onRegenerate,
    super.key,
  });

  final ChatMessage message;
  final String conversationId;

  /// True for the bottom-most bubble — used to gate the trailing copy /
  /// regenerate action bar so only the most recent reply shows quick
  /// actions (matches ChatGPT / Doubao behavior where quick actions live
  /// under the latest reply).
  final bool isLast;

  /// True while the engine is still emitting tokens for the assistant
  /// reply. Quick actions hide during streaming; they fade in once the
  /// stream settles to avoid visual churn.
  final bool isStreaming;

  /// Triggered when the user taps "重新生成". `null` disables the button.
  final VoidCallback? onRegenerate;

  /// Short HH:MM stamp rendered under each bubble. Cheap to format inline
  /// because `createdAt` only goes through `DateFormat` once per rebuild.
  String _stamp(DateTime ts) {
    final l = ts.toLocal();
    final hh = l.hour.toString().padLeft(2, '0');
    final mm = l.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (message.role == MessageRole.user) {
      final scheme = Theme.of(context).colorScheme;
      final sourceText = message.sourceText ?? '';
      final sourceLanguage = _containsChinese(sourceText) ? 'zh-CN' : 'en';
      final tts = ref.read(ttsControllerProvider.notifier);
      return Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(left: 48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Flexible(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _languageLabel(sourceLanguage),
                            style: TextStyle(
                              color: scheme.onPrimary.withValues(alpha: 0.72),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sourceText,
                            style: TextStyle(color: scheme.onPrimary),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              tooltip:
                                  sourceLanguage == 'zh-CN' ? '朗读中文原文' : '朗读原文',
                              visualDensity: VisualDensity.compact,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                              color: scheme.onPrimary,
                              onPressed: () => tts.playMessage(
                                conversationId: conversationId,
                                messageId: message.id,
                                text: sourceText,
                                languageCode: sourceLanguage,
                              ),
                              icon: const Icon(
                                Icons.volume_up_outlined,
                                size: 19,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CircleAvatar(
                    radius: 14,
                    backgroundColor: scheme.primaryContainer,
                    child: Icon(
                      Icons.person_outline,
                      size: 16,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 4, top: 2, bottom: 4),
                child: Text(
                  _stamp(message.createdAt),
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.black45,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final response = message.response!;
    final settings = ref.watch(settingsControllerProvider);
    final settingsController = ref.read(settingsControllerProvider.notifier);
    final ttsState = ref.watch(ttsControllerProvider);
    final tts = ref.read(ttsControllerProvider.notifier);

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CircleAvatar(
                radius: 14,
                child: Icon(Icons.auto_awesome, size: 15),
              ),
              const SizedBox(width: 8),
              Text(
                message.model ?? 'AI Coach',
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
          if (response.thinking.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ThinkingExpansion(thinking: response.thinking),
          ],
          const SizedBox(height: 14),
          if (response.primary.isEmpty && isStreaming)
            const _TypingDots()
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _languageLabel(response.targetLanguage),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                _BubbleText(
                  text: response.primary,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          if (response.alternatives.isNotEmpty) ...[
            const SizedBox(height: 6),
            _BubbleText(
              text: response.alternatives.first,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              _PlaybackButton(
                onWhole: () => tts.playMessage(
                  conversationId: conversationId,
                  messageId: message.id,
                  text: response.primary,
                  languageCode: response.targetLanguage,
                ),
                onPrev: tts.previous,
                onNext: tts.next,
                onStop: tts.stop,
                state: ttsState,
              ),
              const Spacer(),
              PopupMenuButton<double>(
                tooltip: '调整语速',
                position: PopupMenuPosition.under,
                initialValue: settings.speechSpeed,
                onSelected: settingsController.setSpeechSpeed,
                itemBuilder: (context) => _kBubbleSpeedStops
                    .map(
                      (speed) => CheckedPopupMenuItem<double>(
                        value: speed,
                        checked: settings.speechSpeed == speed,
                        child: Text('${speed}x'),
                      ),
                    )
                    .toList(),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.speed_rounded, size: 17),
                      const SizedBox(width: 5),
                      Text(
                        '${settings.speechSpeed}x',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Icon(Icons.arrow_drop_down_rounded, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.black12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('解释', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 5),
                _BubbleText(text: response.explanation),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (response.sentences.isEmpty)
            const Text('（该回复未提供逐句）', style: TextStyle(color: Colors.black45))
          else
            ...response.sentences.asMap().entries.map(
              (entry) {
                final sentenceId = 's_${message.id}_${entry.key}';
                final state = ttsState.sentenceStates[sentenceId] ??
                    SentencePlaybackState.idle;
                // Show the engine's typed error under the failed
                // tile so the user can tell whether the cause is a
                // missing API key, a network blip, or a malformed
                // payload — without this the UI looked identical to
                // a successful but silent playback.
                final errorMessage = state == SentencePlaybackState.failed
                    ? ttsState.lastError?.message
                    : null;
                return _SentenceTile(
                  index: entry.key,
                  text: entry.value.text,
                  conversationId: conversationId,
                  messageId: message.id,
                  playbackState: state,
                  isPlaying: ttsState.currentSentenceId == sentenceId,
                  errorMessage: errorMessage,
                  onPlay: () => tts.playSingleSentence(
                    conversationId: conversationId,
                    messageId: message.id,
                    sentenceId: sentenceId,
                    text: entry.value.text,
                    languageCode: response.targetLanguage,
                  ),
                  onRetry: () => tts.retrySentence(
                    conversationId: conversationId,
                    messageId: message.id,
                    sentenceId: sentenceId,
                    text: entry.value.text,
                    languageCode: response.targetLanguage,
                  ),
                );
              },
            ),
          if (isLast && !isStreaming) ...[
            const SizedBox(height: 10),
            _BubbleActions(
              text: response.primary,
              explanation: response.explanation,
              sentences:
                  response.sentences.map((s) => s.text).toList(growable: false),
              onRegenerate: onRegenerate,
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _stamp(message.createdAt),
              style: const TextStyle(
                fontSize: 10,
                color: Colors.black45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackButton extends StatelessWidget {
  const _PlaybackButton({
    required this.onWhole,
    required this.onPrev,
    required this.onNext,
    required this.onStop,
    required this.state,
  });

  final VoidCallback onWhole;
  final Future<void> Function() onPrev;
  final Future<void> Function() onNext;
  final Future<void> Function() onStop;
  final TtsPlaybackState state;

  @override
  Widget build(BuildContext context) {
    final hasQueue = state.queueLength > 0 || state.currentSentenceId != null;
    final icon = switch (state.playback) {
      AudioPlaybackState.loading => Icons.hourglass_top,
      AudioPlaybackState.playing => Icons.pause_circle_outline,
      AudioPlaybackState.paused => Icons.play_circle_outline,
      AudioPlaybackState.error => Icons.error_outline,
      _ => Icons.volume_up_outlined,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed:
              state.playback == AudioPlaybackState.loading ? null : onWhole,
          icon: Icon(icon),
          tooltip: '播放整段',
        ),
        if (hasQueue) ...[
          IconButton(
            onPressed: () => onPrev(),
            icon: const Icon(Icons.skip_previous),
            tooltip: '上一句',
          ),
          IconButton(
            onPressed: () => onNext(),
            icon: const Icon(Icons.skip_next),
            tooltip: '下一句',
          ),
          IconButton(
            onPressed: () => onStop(),
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: '停止',
          ),
        ],
      ],
    );
  }
}

class _SentenceTile extends StatelessWidget {
  const _SentenceTile({
    required this.index,
    required this.text,
    required this.conversationId,
    required this.messageId,
    required this.playbackState,
    required this.isPlaying,
    required this.onPlay,
    required this.onRetry,
    this.errorMessage,
  });

  final int index;
  final String text;
  final String conversationId;
  final String messageId;
  final SentencePlaybackState playbackState;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onRetry;

  /// When [playbackState] is [SentencePlaybackState.failed], this is
  /// the engine's typed error message so the user can tell a missing
  /// API key from a network blip instead of staring at a silent icon.
  final String? errorMessage;

  IconData _iconForState() {
    if (isPlaying) return Icons.graphic_eq;
    switch (playbackState) {
      case SentencePlaybackState.generating:
        return Icons.hourglass_top;
      case SentencePlaybackState.failed:
        return Icons.error_outline;
      case SentencePlaybackState.cached:
      case SentencePlaybackState.ready:
      case SentencePlaybackState.playing:
      case SentencePlaybackState.paused:
        return Icons.play_circle_outline;
      case SentencePlaybackState.idle:
        return Icons.play_circle_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final highlight =
        isPlaying || playbackState == SentencePlaybackState.generating;
    final failed = playbackState == SentencePlaybackState.failed;
    return InkWell(
      onTap: failed ? onRetry : onPlay,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: highlight
              ? scheme.primaryContainer.withValues(alpha: 0.4)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: failed ? onRetry : onPlay,
              icon: Icon(
                _iconForState(),
                color:
                    failed ? scheme.error : (isPlaying ? scheme.primary : null),
              ),
              tooltip: failed ? '重试' : '播放逐句',
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _BubbleText(
                    text: text,
                    style: TextStyle(
                      fontWeight: isPlaying ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  Text(
                    failed ? '点击重试' : '逐句 ${index + 1}',
                    style: TextStyle(
                      color: failed ? scheme.error : Colors.black45,
                      fontSize: 12,
                    ),
                  ),
                  if (failed &&
                      errorMessage != null &&
                      errorMessage!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        errorMessage!,
                        style: TextStyle(
                          color: scheme.error,
                          fontSize: 11,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Collapsible reasoning section — collapsed by default so the primary
/// answer stays scannable, expandable for users who want to inspect the
/// model's trace. Kept inside the same bubble so the visual link between
/// question / answer / thinking stays obvious.
class _ThinkingExpansion extends StatefulWidget {
  const _ThinkingExpansion({required this.thinking});
  final String thinking;

  @override
  State<_ThinkingExpansion> createState() => _ThinkingExpansionState();
}

class _ThinkingExpansionState extends State<_ThinkingExpansion> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: Colors.black54,
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.psychology_outlined,
                    size: 14,
                    color: Colors.black45,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _expanded ? '收起思考过程' : '展开思考过程',
                    style: const TextStyle(
                      color: Colors.black54,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const SizedBox(height: 6),
            _BubbleText(
              text: widget.thinking,
              style: const TextStyle(
                fontSize: 12.5,
                color: Colors.black54,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Quick-action bar at the bottom of the latest assistant bubble. Mirrors
/// ChatGPT / Doubao / Claude: copy the full answer, or rerun the same
/// request. The bar is hidden on intermediate bubbles and during streaming
/// — both of those states are too volatile to commit to a stable
/// regenerate target.
class _BubbleActions extends StatelessWidget {
  const _BubbleActions({
    required this.text,
    required this.explanation,
    required this.sentences,
    required this.onRegenerate,
  });

  final String text;
  final String explanation;
  final List<String> sentences;
  final VoidCallback? onRegenerate;

  String _composeClipboardPayload() {
    final buf = StringBuffer()..writeln(text);
    if (explanation.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('— 解释 —')
        ..writeln(explanation);
    }
    if (sentences.isNotEmpty) {
      buf
        ..writeln()
        ..writeln('— 逐句 —');
      for (var i = 0; i < sentences.length; i++) {
        buf.writeln('${i + 1}. ${sentences[i]}');
      }
    }
    return buf.toString().trimRight();
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _composeClipboardPayload()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制回答'),
        duration: Duration(milliseconds: 1200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _BubbleIconAction(
          tooltip: '复制回答',
          icon: Icons.content_copy_outlined,
          onTap: () => _copy(context),
        ),
        if (onRegenerate != null) ...[
          const SizedBox(width: 4),
          _BubbleIconAction(
            tooltip: '重新生成',
            icon: Icons.refresh_rounded,
            onTap: onRegenerate!,
          ),
        ],
      ],
    );
  }
}

class _BubbleIconAction extends StatelessWidget {
  const _BubbleIconAction({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: Colors.black54),
        ),
      ),
    );
  }
}

/// Three-dot pulse placeholder shown while the assistant reply is being
/// generated but no tokens have arrived yet. Mirrors the ChatGPT / Claude
/// streaming affordance — keeps the layout stable so the bubble doesn't
/// jump from empty to full-height the moment the first token lands.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              // Stagger each dot's pulse so it reads as a wave.
              final phase = (t + i * 0.18) % 1.0;
              final opacity =
                  0.35 + 0.65 * (1 - (phase - 0.5).abs() * 2).clamp(0.0, 1.0);
              return Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 6),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: opacity),
                    shape: BoxShape.circle,
                  ),
                ),
              );
            }),
          ),
        );
      },
    );
  }
}
