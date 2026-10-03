import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../database/app_database.dart';

/// Persists a row per cached audio file under
/// `files/audio/conversations/{conversationId}/{messageId}/{sentenceId}.wav`.
/// The path lives in [audio_files]; the row carries duration + generation
/// params so future runs can decide whether to re-synthesise or replay.
class AudioCacheRepository {
  AudioCacheRepository(this._appDatabase, {required this.rootDirectory});

  final AppDatabase _appDatabase;
  final Directory rootDirectory;
  Database get _db => _appDatabase.db;

  /// Returns the on-disk path for [sentenceId], creating the directory if
  /// necessary. Synthesised files are written by the active [TtsEngine].
  Future<String> pathFor({
    required String conversationId,
    required String messageId,
    required String sentenceId,
  }) async {
    final dir = Directory(p.join(
      rootDirectory.path,
      'audio',
      'conversations',
      conversationId,
      messageId,
    ));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return p.join(dir.path, '$sentenceId.wav');
  }

  /// Records a successful synthesis. Idempotent — the row is replaced on
  /// re-synthesis so the latest params + duration win.
  Future<void> record({
    required String conversationId,
    required String messageId,
    required String sentenceId,
    required String audioPath,
    required int bytes,
    required String format,
    Duration? duration,
    required String language,
    required String voiceId,
    required double speed,
    required String modelVersion,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.insert(
      'audio_files',
      <String, Object?>{
        'conversation_id': conversationId,
        'message_id': messageId,
        'sentence_id': sentenceId,
        'audio_path': audioPath,
        'bytes': bytes,
        'format': format,
        'duration_ms': duration?.inMilliseconds,
        'language': language,
        'voice_id': voiceId,
        'speed': speed,
        'model_version': modelVersion,
        'created_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<({String audioPath, Duration? duration})?> lookup({
    required String conversationId,
    required String messageId,
    required String sentenceId,
  }) async {
    final rows = await _db.query(
      'audio_files',
      where: 'conversation_id = ? AND message_id = ? AND sentence_id = ?',
      whereArgs: [conversationId, messageId, sentenceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final durationMs = row['duration_ms'] as int?;
    return (
      audioPath: row['audio_path'] as String,
      duration: durationMs == null ? null : Duration(milliseconds: durationMs),
    );
  }

  /// Remove the cached row + audio file for a single sentence. Used by
  /// [TtsController.retrySentence] so the next play falls back to the
  /// engine instead of replaying a stale artifact.
  Future<void> invalidate({
    required String conversationId,
    required String messageId,
    required String sentenceId,
  }) async {
    final rows = await _db.query(
      'audio_files',
      columns: const ['audio_path'],
      where: 'conversation_id = ? AND message_id = ? AND sentence_id = ?',
      whereArgs: [conversationId, messageId, sentenceId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final path = rows.first['audio_path'] as String?;
    await _db.delete(
      'audio_files',
      where: 'conversation_id = ? AND message_id = ? AND sentence_id = ?',
      whereArgs: [conversationId, messageId, sentenceId],
    );
    if (path != null) {
      final file = File(path);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {
          // best-effort — leave the file in place if it's locked; the
          // SQLite record is gone so the next lookup will re-synthesise.
        }
      }
    }
  }

  Future<void> deleteForConversation(String conversationId) async {
    await _db.delete(
      'audio_files',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
    );
    final dir = Directory(p.join(
      rootDirectory.path,
      'audio',
      'conversations',
      conversationId,
    ));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// Walks the on-disk audio directory and deletes any file that the
  /// SQLite cache does not know about. Returns the number of orphan files
  /// removed. Call this once at startup.
  Future<int> cleanupOrphans() async {
    final tracked = <String>{
      for (final row in await _db.query('audio_files'))
        row['audio_path'] as String,
    };
    final root = Directory(p.join(
      rootDirectory.path,
      'audio',
      'conversations',
    ));
    if (!root.existsSync()) return 0;
    var removed = 0;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is File && !tracked.contains(entity.path)) {
        try {
          entity.deleteSync();
          removed++;
        } catch (_) {
          // best-effort — leave the file in place if it's locked.
        }
      }
    }
    return removed;
  }
}
