import 'package:flutter/material.dart';

import '../application/chat_session_state.dart';

/// Placeholder for the Rive character. Renders a circle that pulses in
/// sync with the current session phase so the chat page has a visible
/// "who's talking" affordance before the real Rive runtime ships.
///
/// P2-1 keeps this deliberately simple — the .riv asset and the
/// `flutter_rive` package land once the character design is finalised.
/// The shape / size contract here stays the same, so the swap is a
/// one-file change.
class SessionCharacter extends StatelessWidget {
  const SessionCharacter({
    super.key,
    required this.phase,
    this.size = 96,
  });

  final ChatSessionPhase phase;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(phase, Theme.of(context));
    return SizedBox.square(
      dimension: size,
      child: _PulsingCircle(
        phase: phase,
        color: color,
        child: Icon(_iconFor(phase), size: size * 0.5, color: Colors.white),
      ),
    );
  }

  static Color _colorFor(ChatSessionPhase phase, ThemeData theme) {
    switch (phase) {
      case ChatSessionPhase.idle:
        return theme.colorScheme.primary.withValues(alpha: 0.7);
      case ChatSessionPhase.recording:
        return theme.colorScheme.error;
      case ChatSessionPhase.processing:
        return theme.colorScheme.tertiary;
      case ChatSessionPhase.playing:
        return theme.colorScheme.secondary;
      case ChatSessionPhase.error:
        return theme.colorScheme.error.withValues(alpha: 0.85);
    }
  }

  static IconData _iconFor(ChatSessionPhase phase) {
    switch (phase) {
      case ChatSessionPhase.idle:
        return Icons.mic_none_outlined;
      case ChatSessionPhase.recording:
        return Icons.mic;
      case ChatSessionPhase.processing:
        return Icons.hourglass_top;
      case ChatSessionPhase.playing:
        return Icons.volume_up;
      case ChatSessionPhase.error:
        return Icons.warning_amber_rounded;
    }
  }
}

class _PulsingCircle extends StatefulWidget {
  const _PulsingCircle({
    required this.phase,
    required this.color,
    required this.child,
  });

  final ChatSessionPhase phase;
  final Color color;
  final Widget child;

  @override
  State<_PulsingCircle> createState() => _PulsingCircleState();
}

class _PulsingCircleState extends State<_PulsingCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        // Phases that should pulse: recording + processing + playing.
        // idle/error stay still so the user can read the icon.
        final shouldPulse = widget.phase == ChatSessionPhase.recording ||
            widget.phase == ChatSessionPhase.processing ||
            widget.phase == ChatSessionPhase.playing;
        final pulse = shouldPulse ? (1 - t) : 1.0;
        return Stack(
          alignment: Alignment.center,
          children: [
            if (shouldPulse)
              Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: 0.18 * pulse),
                ),
              ),
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
              ),
              padding: const EdgeInsets.all(8),
              child: child,
            ),
          ],
        );
      },
      child: widget.child,
    );
  }
}