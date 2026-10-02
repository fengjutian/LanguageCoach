import 'package:flutter/material.dart';
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
      h1: base.copyWith(fontSize: (base.fontSize ?? 14) * 1.6, fontWeight: FontWeight.w700),
      h2: base.copyWith(fontSize: (base.fontSize ?? 14) * 1.4, fontWeight: FontWeight.w700),
      h3: base.copyWith(fontSize: (base.fontSize ?? 14) * 1.2, fontWeight: FontWeight.w700),
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
    super.key,
  });

  final ChatMessage message;
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (message.role == MessageRole.user) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          constraints: const BoxConstraints(maxWidth: 330),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            message.sourceText ?? '',
            style: TextStyle(color: Theme.of(context).colorScheme.onPrimary),
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
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
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
          _BubbleText(
            text: response.primary,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          ),
          if (response.alternatives.isNotEmpty) ...[
            const SizedBox(height: 6),
            _BubbleText(
              text: response.alternatives.first,
              style: const TextStyle(color: Colors.black54),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            children: [
              _PlaybackButton(
                onWhole: () => tts.playMessage(
                  conversationId: conversationId,
                  messageId: message.id,
                  text: response.primary,
                ),
                onPrev: tts.previous,
                onNext: tts.next,
                onStop: tts.stop,
                state: ttsState,
              ),
              ..._kBubbleSpeedStops.map(
                (speed) => ChoiceChip(
                  label: Text('${speed}x'),
                  selected: settings.speechSpeed == speed,
                  onSelected: (_) => settingsController.setSpeechSpeed(speed),
                ),
              ),
            ],
          ),
          const Divider(height: 28),
          const Text('解释', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          _BubbleText(text: response.explanation),
          const SizedBox(height: 14),
          if (response.sentences.isEmpty)
            const Text('（该回复未提供逐句）', style: TextStyle(color: Colors.black45))
          else
            ...response.sentences.asMap().entries.map(
                  (entry) => _SentenceTile(
                    index: entry.key,
                    text: entry.value.text,
                    conversationId: conversationId,
                    messageId: message.id,
                    playbackState: ttsState
                            .sentenceStates['s_${message.id}_${entry.key}'] ??
                        SentencePlaybackState.idle,
                    isPlaying: ttsState.currentSentenceId ==
                        's_${message.id}_${entry.key}',
                    onPlay: () => tts.playSingleSentence(
                      conversationId: conversationId,
                      messageId: message.id,
                      sentenceId: 's_${message.id}_${entry.key}',
                      text: entry.value.text,
                    ),
                    onRetry: () => tts.retrySentence(
                      conversationId: conversationId,
                      messageId: message.id,
                      sentenceId: 's_${message.id}_${entry.key}',
                      text: entry.value.text,
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
  });

  final int index;
  final String text;
  final String conversationId;
  final String messageId;
  final SentencePlaybackState playbackState;
  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onRetry;

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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
            const SizedBox(width: 8),
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
