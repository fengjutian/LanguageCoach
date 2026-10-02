import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/asr_engine.dart';
import '../../../core/platform/app_settings.dart';
import '../../../core/ui/app_toast.dart';
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
    this.onOpenSettings,
  });

  final SessionError error;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onOpenSettings;

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

    Future<void> openSettings() async {
      try {
        await (onOpenSettings ?? AppSettings.open)();
      } on PlatformException {
        if (!context.mounted) return;
        AppToast.error(context, '无法打开系统设置，请手动为应用开启麦克风权限');
      }
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
              onPressed: openSettings,
              style: TextButton.styleFrom(foregroundColor: fg),
              child: const Text('设置'),
            ),
        ],
      ),
    );
  }
}
