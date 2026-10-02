import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/ai/conversation_repository.dart';
import '../../core/database/app_database.dart';

/// SQLite-backed key/value settings store. Values are stored as JSON so
/// [AppSettings.fromJson] can rehydrate on startup without losing types.
class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(this._appDatabase);
  final AppDatabase _appDatabase;

  Database get _db => _appDatabase.db;

  @override
  Future<Map<Object?, Object?>> loadRaw() async {
    final rows = await _db.query('settings');
    return <String, Object?>{
      for (final row in rows)
        row['key'] as String: _tryDecode(row['value'] as String),
    };
  }

  @override
  Future<void> saveRaw(Map<Object?, Object?> raw) async {
    await _db.transaction((txn) async {
      for (final entry in raw.entries) {
        final value = entry.value;
        await txn.insert(
          'settings',
          <String, Object?>{
            'key': entry.key.toString(),
            'value': json.encode(value),
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<void> clearAll() async {
    await _db.delete('settings');
  }

  Object? _tryDecode(String raw) {
    return json.decode(raw);
  }
}
