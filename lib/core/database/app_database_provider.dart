import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/ai/conversation_repository.dart';
import '../../../core/database/app_database.dart';
import '../../../core/repositories/sqlite_conversation_repository.dart';
import '../../../core/repositories/sqlite_settings_repository.dart';

/// Application database. Override this provider in `main()` after
/// `AppDatabase.open()` resolves for the production on-disk database.
/// A synchronous in-memory fallback is provided so the app can start
/// without a crash when the override is accidentally omitted.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  // Use an in-memory database as the fallback. This lets the app start
  // without a crash in development or widget tests.
  return _openInMemorySync();
});

/// Opens an in-memory SQLite database synchronously for fallback use.
AppDatabase _openInMemorySync() {
  // Synchronous open only works with `:memory:` paths in sqflite.
  final db = openDatabaseSync(
    inMemoryDatabasePath,
    version: AppDatabase.schemaVersion,
    onConfigure: (db) async {
      await db.execute('PRAGMA foreign_keys = ON');
    },
  );
  return AppDatabase._(db);
}

/// Async initialization helper. Call this in main() before runApp() and
/// override the provider:
///
/// ```dart
/// final db = await AppDatabase.open();
/// ref.defineOverride(appDatabaseProvider, (_) => db);
/// ```
Future<AppDatabase> createDatabase() => AppDatabase.open();

final conversationRepositoryProvider = Provider<ConversationRepository>((ref) {
  return SqliteConversationRepository(ref.watch(appDatabaseProvider));
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SqliteSettingsRepository(ref.watch(appDatabaseProvider));
});
