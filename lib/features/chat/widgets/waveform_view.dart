import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/waveform_controller.dart';

/// Painted bar graph of the most recent ASR RMS levels. Sized to fit the
/// composer area; renders an empty baseline when no samples have arrived.
class WaveformView extends ConsumerWidget {
  const WaveformView({super.key, this.height = 36, this.barColor});

  final double height;
  final Color? barColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(waveformControllerProvider);
    final color = barColor ?? Theme.of(context).colorScheme.primary;
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _WaveformPainter(
          levels: state.levels,
          color: color,
          baseline: Theme.of(context).colorScheme.outlineVariant,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.levels,
    required this.color,
    required this.baseline,
  });

  final List<double> levels;
  final Color color;
  final Color baseline;

  @override
  void paint(Canvas canvas, Size size) {
    // Baseline rule — anchors the bars so the silence state still shows
    // a visible strip instead of vanishing.
    final mid = size.height / 2;
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = baseline
        ..strokeWidth = 1,
    );

    if (levels.isEmpty) return;

    const gap = 2.0;
    final barWidth =
        math.max(2.0, (size.width - gap * (levels.length - 1)) / levels.length);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    for (var i = 0; i < levels.length; i++) {
      final amp = levels[i].clamp(0.0, 1.0);
      final x = i * (barWidth + gap);
      final barHeight = math.max(2.0, amp * size.height);
      final top = mid - barHeight / 2;
      final bottom = mid + barHeight / 2;
      canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter old) {
    return old.levels != levels || old.color != color;
  }
}