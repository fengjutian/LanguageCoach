import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ai/conversation_repository.dart';
import 'conversation_export_service.dart';
import 'conversation_exporter.dart';

/// Default share backend used in production. Tests inject a fake via
/// the provider override.
final shareServiceProvider = Provider<ShareService>((_) {
  return const SystemShareService();
});

/// Default export service used in production.
final conversationExportServiceProvider =
    Provider<ConversationExportService>((ref) {
  return ConversationExportService(
    repository: ref.read(conversationRepositoryProvider),
    exporter: const ConversationExporter(),
    share: ref.read(shareServiceProvider),
    tempDirectoryProvider: () async => Directory(
          // Fallback when path_provider isn't available (host VM tests
          // without WidgetsBinding). Production overrides this with the
          // real platform temp dir via path_provider.
          Directory.systemTemp,
        ),
  );
});

/// One-shot export trigger. We intentionally return a [FutureProvider] so
/// the UI can render a spinner / disable the button while the file is
/// being written, then surface the resulting path via a snackbar.
final exportConversationProvider =
    FutureProvider.family<String, String>((ref, conversationId) async {
  return ref
      .read(conversationExportServiceProvider)
      .export(conversationId);
});
