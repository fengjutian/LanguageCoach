import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/asr_engine.dart';
import '../application/chat_session_state.dart';
import '../application/speech_session_controller.dart';

/// Compact card surfaced above the composer when the last action failed.
/// Three affordances:
///   * Retry — invokes [SpeechSessionController.start] (or the parent's
///     `onRetry` override when the parent knows more about the failure).
///   * Cancel — drops the partial text and goes back to idle.
///   * Open settings — only for permission / unavailable errors so the
///     user can flip the system toggle without hunting through the app.
class SessionErrorCard extends ConsumerWidget {
  const SessionErrorCard({
    super.key,
    required this.error,
    this.onRetry,
  });

  final SessionError error;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.errorContainer;
    final fg = theme.colorScheme.onErrorContainer;

    Future<void> retry() async {
      if (onRetry != null) {
        await onRetry!();
        return;
      }
      // Default: kick the speech session. That's the most common reason
      // the error card appears and keeps the retry path simple.
      await ref.read(speechSessionControllerProvider.notifier).start();
    }

    final showOpenSettings = error.kind == AsrErrorKind.permissionDenied ||
        error.kind == AsrErrorKind.unavailable;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error.message,
              style: theme.textTheme.bodyMedium?.copyWith(color: fg),
            ),
          ),
          if (error.retryable)
            TextButton(
              onPressed: retry,
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('重试'),
            ),
          if (showOpenSettings)
            TextButton(
              onPressed: () {
                // Stub: a real implementation launches the system settings
                // intent via a platform channel. P2-1 keeps this as a
                // no-op until the system settings bridge lands.
              },
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('设置'),
            ),
        ],
      ),
    );
  }
}