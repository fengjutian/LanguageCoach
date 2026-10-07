import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/ai/conversation_repository.dart';
import '../../core/database/app_database.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/chat_models.dart';

/// SQLite-backed conversation repository. The first version stores
/// conversations, messages and sentences; cascades ensure deleting a
/// conversation removes its messages and sentences atomically.
class SqliteConversationRepository implements ConversationRepository {
  SqliteConversationRepository(this._appDatabase);
  final AppDatabase _appDatabase;

  Database get _db => _appDatabase.db;

  /// Idempotently create the conversation row if missing. Returns the
  /// existing row untouched otherwise.
  @override
  Future<void> ensureConversation(
    String id, {
    String? title,
    CoachLanguage? preferredLanguage,
    CoachLanguage? targetLanguage,
    DateTime? createdAt,
  }) async {
    final existing = await _db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final now = DateTime.now().millisecondsSinceEpoch;
    if (existing.isEmpty) {
      await _db.insert('conversations', <String, Object?>{
        'id': id,
        'title': title ?? _defaultTitle(),
        'preferred_language': preferredLanguage?.name,
        'target_language': targetLanguage?.name,
        'created_at': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
        'updated_at': now,
      });
    } else if (title != null && _isAutoTitle(existing.first['title'] as String?)) {
      // `_defaultTitle()` re-derives the timestamp at call time, so the old
      // `== _defaultTitle()` guard could only match within the same minute
      // of creation — the branch was effectively dead. Match the shape
      // instead, and only replace it if it really is an auto title.
      await updateTitle(id, title);
    }
  }

  /// True when [title] is one of the placeholder titles this repository
  /// generates, i.e. it has not been named by the user or by the chat page.
  static bool _isAutoTitle(String? title) {
    if (title == null) return false;
    return RegExp(r'^对话 \d{2}-\d{2} \d{2}:\d{2}$').hasMatch(title);
  }

  @override
  Future<void> updateTitle(String conversationId, String title) async {
    await _db.update(
      'conversations',
      <String, Object?>{
        'title': title,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  @override
  Future<({String id, String title, DateTime updatedAt})?> findById(
      String conversationId) async {
    final rows = await _db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      id: row['id'] as String,
      title: row['title'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  @override
  Future<List<ChatMessage>> messagesFor(String conversationId) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at ASC',
    );
    // Skip the sentence query when there are no messages, otherwise we
    // build `WHERE message_id IN ()` which SQLite rejects.
    final sentencesByMessage = <String, List<CoachSentence>>{};
    if (rows.isNotEmpty) {
      final sentenceRows = await _db.rawQuery(
        'SELECT message_id, sentence_index, id, text FROM sentences '
        'WHERE message_id IN (${rows.map((_) => '?').join(',')}) '
        'ORDER BY message_id, sentence_index ASC',
        rows.map((r) => r['id'] as String).toList(),
      );
      for (final row in sentenceRows) {
        final messageId = row['message_id'] as String;
        final list =
            sentencesByMessage.putIfAbsent(messageId, () => <CoachSentence>[]);
        list.add(CoachSentence(
          id: row['id'] as String,
          text: row['text'] as String,
        ));
      }
    }

    return rows.map((row) {
      final role = MessageRole.values.firstWhere(
        (r) => r.name == row['role'],
        orElse: () => MessageRole.user,
      );
      final responseRaw = row['response_json'] as String?;
      CoachResponse? response;
      if (responseRaw != null && responseRaw.isNotEmpty) {
        try {
          final decoded = json.decode(responseRaw);
          if (decoded is Map) {
            response = CoachResponse.fromJson(decoded.cast<String, Object?>());
          }
        } catch (_) {
          // tolerate malformed JSON — treat the message as response-less
        }
      }
      return ChatMessage(
        id: row['id'] as String,
        role: role,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        sourceText: row['source_text'] as String?,
        response: response?.copyWith(
          sentences:
              sentencesByMessage[row['id'] as String] ?? response.sentences,
        ),
        model: row['model'] as String?,
      );
    }).toList();
  }

  @override
  Future<String> appendMessage({
    required String conversationId,
    required ChatMessage message,
  }) async {
    await ensureConversation(conversationId);
    final sentences = message.response?.sentences ?? const <CoachSentence>[];
    await _db.transaction((txn) async {
      await txn.insert(
        'messages',
        <String, Object?>{
          'id': message.id,
          'conversation_id': conversationId,
          'role': message.role.name,
          'source_text': message.sourceText,
          'response_json': message.response == null
              ? null
              : json.encode(message.response!.toJson()),
          'model': message.model,
          'created_at': message.createdAt.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      for (var i = 0; i < sentences.length; i++) {
        final s = sentences[i];
        await txn.insert(
          'sentences',
          <String, Object?>{
            'message_id': message.id,
            'sentence_index': i,
            'id': s.id,
            'text': s.text,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await txn.update(
        'conversations',
        <String, Object?>{
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [conversationId],
      );
    });
    return message.id;
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    await _db.delete(
      'conversations',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
  }

  @override
  Future<List<({String id, String preview, DateTime updatedAt})>>
      recentConversations({int limit = 50, String? query}) async {
    final trimmedQuery = query?.trim();
    final where = trimmedQuery == null || trimmedQuery.isEmpty
        ? null
        : "(title LIKE ? ESCAPE '\\' OR EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = conversations.id AND m.source_text LIKE ? ESCAPE '\\'))";
    // Escape SQL LIKE wildcards so user input doesn't get interpreted as
    // a pattern: `%` (any), `_` (single char), and `\` (escape itself).
    final escaped = _escapeLike(trimmedQuery ?? '');
    final args = trimmedQuery == null || trimmedQuery.isEmpty
        ? null
        : <Object?>['%$escaped%', '%$escaped%'];
    final rows = await _db.query(
      'conversations',
      where: where,
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: limit,
    );

    final previews = <String, String>{};
    final ids = rows.map((r) => r['id'] as String).toList();
    if (ids.isNotEmpty) {
      final placeholder = List.filled(ids.length, '?').join(',');
      // The LIMIT here is a *global* cap on the result set, so binding
      // `ids.length` returned at most N rows across all conversations
      // instead of N per conversation: any conversation whose latest user
      // message ranked below the cut got no row at all and rendered with a
      // blank preview. Take the newest message per conversation instead.
      final msgRows = await _db.rawQuery(
        'SELECT m.conversation_id, m.source_text FROM messages m '
        'JOIN (SELECT conversation_id, MAX(created_at) AS latest '
        '      FROM messages WHERE role = ? AND conversation_id IN '
        '($placeholder) GROUP BY conversation_id) newest '
        '  ON m.conversation_id = newest.conversation_id '
        ' AND m.created_at = newest.latest '
        'WHERE m.role = ?',
        [MessageRole.user.name, ...ids, MessageRole.user.name],
      );
      for (final row in msgRows) {
        final id = row['conversation_id'] as String;
        previews.putIfAbsent(id, () => row['source_text'] as String? ?? '');
      }
    }

    return rows.map((row) {
      final id = row['id'] as String;
      return (
        id: id,
        preview: previews[id] ?? '',
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
      );
    }).toList();
  }

  @override
  Future<void> deleteAllConversations() async {
    await _db.delete('conversations');
  }

  String _defaultTitle() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '对话 $m-$d $hh:$mm';
  }

  /// Escape SQL LIKE wildcards so user-typed search terms don't get
  /// interpreted as patterns. The default escape character is `\`.
  ///
  /// The escaping is only effective because the queries carry an explicit
  /// `ESCAPE '\'` clause — SQLite's LIKE has *no* default escape character,
  /// so without it `\%` was a literal backslash followed by a live wildcard.
  static String _escapeLike(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
  }
}
