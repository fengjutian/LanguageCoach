import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

/// Singleton-style holder for the application database. Tests can pass an
/// in-memory path (`:memory:`) to bypass the file system entirely. The
/// migration list is intentionally tiny — v1 ships the full schema; future
/// versions append to [migrations].
class AppDatabase {
  AppDatabase._(this._db);

  static const int schemaVersion = 1;

  final Database _db;
  Database get db => _db;

  static Future<AppDatabase> open({String? overridePath}) async {
    final path = overridePath ?? await _defaultPath();
    final db = await openDatabase(
      path,
      version: schemaVersion,
      onConfigure: _onConfigure,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
    return AppDatabase._(db);
  }

  Future<void> close() => _db.close();

  static Future<String> _defaultPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'language_coach.db');
  }

  static Future<void> _onConfigure(Database db) async {
    // Foreign keys are required for the `ON DELETE CASCADE` clauses to
    // cascade when a conversation is deleted.
    await db.execute('PRAGMA foreign_keys = ON');
  }

  static Future<void> _onCreate(Database db, int version) async {
    for (final step in migrations) {
      await step.up(db);
    }
  }

  static Future<void> _onUpgrade(
      Database db, int oldVersion, int newVersion) async {
    for (final step in migrations) {
      if (step.targetVersion > oldVersion && step.targetVersion <= newVersion) {
        await step.up(db);
      }
    }
  }
}

/// One forward migration step. Bumping [schemaVersion] means adding another
/// [MigrationStep] to [migrations] (with `targetVersion = newVersion`).
class MigrationStep {
  const MigrationStep(this.targetVersion, this.statements);
  final int targetVersion;
  final List<String> statements;
  Future<void> up(Database db) async {
    final batch = db.batch();
    for (final stmt in statements) {
      batch.execute(stmt);
    }
    await batch.commit(noResult: true);
  }
}

final List<MigrationStep> migrations = <MigrationStep>[
  MigrationStep(1, <String>[
    '''
    CREATE TABLE conversations (
      id TEXT PRIMARY KEY,
      title TEXT NOT NULL,
      preferred_language TEXT,
      target_language TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
    ''',
    'CREATE INDEX idx_conversations_updated ON conversations(updated_at DESC)',
    '''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL,
      role TEXT NOT NULL,
      source_text TEXT,
      response_json TEXT,
      model TEXT,
      created_at INTEGER NOT NULL,
      FOREIGN KEY (conversation_id) REFERENCES conversations(id) ON DELETE CASCADE
    )
    ''',
    'CREATE INDEX idx_messages_conv ON messages(conversation_id, created_at)',
    '''
    CREATE TABLE sentences (
      message_id TEXT NOT NULL,
      sentence_index INTEGER NOT NULL,
      id TEXT NOT NULL,
      text TEXT NOT NULL,
      PRIMARY KEY (message_id, sentence_index),
      FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
    )
    ''',
    '''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE voice_profiles (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      language TEXT NOT NULL,
      display_name TEXT NOT NULL,
      sample_audio_path TEXT,
      config_json TEXT,
      created_at INTEGER NOT NULL
    )
    ''',
    '''
    CREATE TABLE model_records (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      version TEXT NOT NULL,
      size_bytes INTEGER NOT NULL,
      download_url TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      local_path TEXT,
      status TEXT NOT NULL,
      installed_at INTEGER
    )
    ''',
    '''
    CREATE TABLE audio_files (
      conversation_id TEXT NOT NULL,
      message_id TEXT NOT NULL,
      sentence_id TEXT NOT NULL,
      audio_path TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      format TEXT NOT NULL,
      duration_ms INTEGER,
      language TEXT NOT NULL,
      voice_id TEXT NOT NULL,
      speed REAL NOT NULL,
      model_version TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      PRIMARY KEY (conversation_id, message_id, sentence_id)
    )
    ''',
  ]),
];
