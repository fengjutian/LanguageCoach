import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ai/conversation_repository.dart';
import '../../../core/database/app_database.dart';
import '../../../core/repositories/sqlite_conversation_repository.dart';
import '../../../core/repositories/sqlite_settings_repository.dart';

/// Override this provider in `main()` after `AppDatabase.open()` resolves so
/// the rest of the app reads from the real on-disk database without
/// awaiting it everywhere.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  throw UnimplementedError(
    'appDatabaseProvider must be overridden in main() after AppDatabase.open()',
  );
});

final conversationRepositoryProvider = Provider<ConversationRepository>((ref) {
  return SqliteConversationRepository(ref.watch(appDatabaseProvider));
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SqliteSettingsRepository(ref.watch(appDatabaseProvider));
});
