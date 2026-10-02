import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database_provider.dart';
import 'conversation_export_service.dart';
import 'conversation_exporter.dart';

/// Default share backend used in production. Tests inject a fake via
/// the provider override.
final shareServiceProvider = Provider<ShareService>((_) {
  return const SystemShareService();
});

/// Default export service used in production. The constructor's default
/// `tempDirectoryProvider` reads via `path_provider`, which is enough for
/// production builds; tests inject a stub directory instead.
final conversationExportServiceProvider =
    Provider<ConversationExportService>((ref) {
  return ConversationExportService(
    repository: ref.read(conversationRepositoryProvider),
    exporter: const ConversationExporter(),
    share: ref.read(shareServiceProvider),
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
