import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/database/app_database.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/repositories/sqlite_conversation_repository.dart';
import 'package:language_coach/features/chat/application/chat_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// SQLite-level guarantees the chat controller depends on: full metadata
/// round-trip, language updates that preserve `created_at`, cascade deletes,
/// and a regenerate that keeps the transcript length stable.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late Directory tmp;
  late SqliteConversationRepository repo;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('conversation_repo_test_');
    db = await AppDatabase.open(overridePath: '${tmp.path}/test.db');
    repo = SqliteConversationRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ChatMessage user(String id, String text, {DateTime? at}) => ChatMessage(
        id: id,
        role: MessageRole.user,
        createdAt: at ?? DateTime(2026),
        sourceText: text,
      );

  ChatMessage assistant(
    String id,
    String text, {
    String language = 'ja',
    DateTime? at,
    ChatMessageStatus status = ChatMessageStatus.completed,
  }) =>
      ChatMessage(
        id: id,
        role: MessageRole.assistant,
        createdAt: at ?? DateTime(2026, 1, 1, 0, 0, 1),
        status: status,
        response: CoachResponse(
          intent: CoachIntent.conversation,
          sourceLanguage: 'auto',
          targetLanguage: language,
          primary: text,
          explanation: '',
          sentences: <CoachSentence>[CoachSentence(id: 's_$id', text: text)],
        ),
      );

  test('conversation metadata round-trips in full', () async {
    await repo.ensureConversation(
      'c1',
      title: '朝 talk',
      preferredLanguage: CoachLanguage.english,
      targetLanguage: CoachLanguage.japanese,
    );
    await repo.appendMessage(conversationId: 'c1', message: user('u1', '你好'));

    final meta = await repo.getConversation('c1');
    expect(meta, isNotNull);
    expect(meta!.id, 'c1');
    expect(meta.title, '朝 talk');
    expect(meta.preferredLanguage, CoachLanguage.english);
    expect(meta.targetLanguage, CoachLanguage.japanese);
    expect(meta.createdAt, isA<DateTime>());
  });

  test('a conversation with no language columns falls back to English',
      () async {
    await repo.ensureConversation('c1', title: 'legacy');
    final meta = await repo.getConversation('c1');
    expect(meta?.preferredLanguage, CoachLanguage.english);
    expect(meta?.targetLanguage, CoachLanguage.english);
  });

  test('updating the target language does not move created_at', () async {
    await repo.ensureConversation(
      'c1',
      preferredLanguage: CoachLanguage.english,
      targetLanguage: CoachLanguage.english,
    );
    final before = await repo.getConversation('c1');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await repo.updateConversationLanguage('c1', CoachLanguage.german);

    final after = await repo.getConversation('c1');
    expect(after!.createdAt, before!.createdAt);
    expect(after.targetLanguage, CoachLanguage.german);
    expect(after.updatedAt.isBefore(before.updatedAt), isFalse);
  });

  test('message status survives the round trip', () async {
    await repo.ensureConversation('c1');
    await repo.appendMessage(
      conversationId: 'c1',
      message: assistant('a1', 'こんにちは', status: ChatMessageStatus.cancelled),
    );

    final messages = await repo.messagesFor('c1');
    expect(messages.single.status, ChatMessageStatus.cancelled);
    expect(
      messages.single.isContextEligible,
      isFalse,
      reason: 'a stopped turn must never be replayed to the model',
    );
  });

  test('messages saved in the same millisecond keep insertion order', () async {
    await repo.ensureConversation('c1');
    final stamp = DateTime(2026, 3, 3, 12);
    for (var i = 0; i < 4; i++) {
      await repo.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: i.isEven ? 'u_$i' : 'a_$i',
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          createdAt: stamp,
          sourceText: i.isEven ? 'q$i' : null,
          response: i.isEven
              ? null
              : CoachResponse(
                  intent: CoachIntent.conversation,
                  sourceLanguage: 'auto',
                  targetLanguage: 'en',
                  primary: 'a$i',
                  explanation: '',
                  sentences: const <CoachSentence>[],
                ),
        ),
      );
    }

    final messages = await repo.messagesFor('c1');
    expect(messages.map((m) => m.id), ['u_0', 'a_1', 'u_2', 'a_3']);
  });

  test('a streaming placeholder is never context-eligible', () async {
    final placeholder = ChatMessage(
      id: 'a_pending',
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      status: ChatMessageStatus.streaming,
    );
    expect(placeholder.isContextEligible, isFalse);
  });

  test('regenerate replaces the answer without growing the transcript',
      () async {
    await repo.ensureConversation('c1');
    // Strictly increasing timestamps: the transcript is ordered by
    // created_at, so an answer stamped *after* the next question would be a
    // nonsensical fixture rather than a regenerate bug.
    var at = 0;
    DateTime next() => DateTime(2026, 3, 3, 12).add(Duration(seconds: at++));

    await repo.appendMessage(
      conversationId: 'c1',
      message: user('u1', '你好', at: next()),
    );
    await repo.appendMessage(
      conversationId: 'c1',
      message: assistant('a1', 'partial…',
          at: next(), status: ChatMessageStatus.failed),
    );
    await repo.appendMessage(
      conversationId: 'c1',
      message: user('u2', '再来', at: next()),
    );
    await repo.appendMessage(
      conversationId: 'c1',
      message: assistant('a2', 'はい', at: next()),
    );

    await repo.replaceAssistantTurn(
      conversationId: 'c1',
      userMessageId: 'u2',
      assistant: assistant('a2b', 'はい、新しく', at: next()),
    );

    final messages = await repo.messagesFor('c1');
    expect(messages, hasLength(4));
    expect(
      messages.where((m) => m.role == MessageRole.assistant).map((m) => m.id),
      <String>['a1', 'a2b'],
    );
    expect(messages.last.response?.primary, 'はい、新しく');
  });

  test('regenerate never removes an earlier turn that shares a timestamp',
      () async {
    await repo.ensureConversation('c1');
    final stamp = DateTime(2026, 3, 3, 12);
    ChatMessage at(String id, MessageRole role, String text) => ChatMessage(
          id: id,
          role: role,
          createdAt: stamp,
          sourceText: role == MessageRole.user ? text : null,
          response: role == MessageRole.user
              ? null
              : CoachResponse(
                  intent: CoachIntent.conversation,
                  sourceLanguage: 'auto',
                  targetLanguage: 'en',
                  primary: text,
                  explanation: '',
                  sentences: const <CoachSentence>[],
                ),
        );
    await repo.appendMessage(
        conversationId: 'c1', message: at('u1', MessageRole.user, 'q1'));
    await repo.appendMessage(
        conversationId: 'c1', message: at('a1', MessageRole.assistant, 'a1'));
    await repo.appendMessage(
        conversationId: 'c1', message: at('u2', MessageRole.user, 'q2'));
    await repo.appendMessage(
        conversationId: 'c1', message: at('a2', MessageRole.assistant, 'a2'));

    await repo.replaceAssistantTurn(
      conversationId: 'c1',
      userMessageId: 'u2',
      assistant: at('a2b', MessageRole.assistant, 'regenerated'),
    );

    final messages = await repo.messagesFor('c1');
    expect(messages.map((m) => m.id), ['u1', 'a1', 'u2', 'a2b']);
  });

  test('regenerate deletes the sentences of the turn it replaces', () async {
    await repo.ensureConversation('c1');
    await repo.appendMessage(conversationId: 'c1', message: user('u1', '你好'));
    await repo.appendMessage(
      conversationId: 'c1',
      message: assistant('a1', 'old sentence'),
    );
    final before = await db.db.rawQuery(
        'SELECT COUNT(*) AS n FROM sentences WHERE message_id = ?', ['a1']);
    expect(before.first['n'], 1);

    await repo.replaceAssistantTurn(
      conversationId: 'c1',
      userMessageId: 'u1',
      assistant: assistant('a2', '新しい文'),
    );

    final after = await db.db.rawQuery(
        'SELECT COUNT(*) AS n FROM sentences WHERE message_id = ?', ['a1']);
    expect(after.first['n'], 0,
        reason: 'the replaced turn must not leave orphaned audio metadata');
  });

  test('regenerate falls back to an append when the anchor is gone', () async {
    await repo.ensureConversation('c1');
    await repo.appendMessage(conversationId: 'c1', message: user('u1', '你好'));

    await repo.replaceAssistantTurn(
      conversationId: 'c1',
      userMessageId: 'missing',
      assistant: assistant('a9', 'answer'),
    );

    final messages = await repo.messagesFor('c1');
    expect(messages.map((m) => m.id), containsAll(<String>['u1', 'a9']));
  });

  test('deleting a conversation cascades to messages and sentences', () async {
    await repo.ensureConversation('c1');
    await repo.appendMessage(conversationId: 'c1', message: user('u1', '你好'));
    await repo.appendMessage(
        conversationId: 'c1', message: assistant('a1', 'こんにちは'));

    await repo.deleteConversation('c1');

    expect(await repo.getConversation('c1'), isNull);
    expect(await repo.messagesFor('c1'), isEmpty);
    final sentences =
        await db.db.rawQuery('SELECT COUNT(*) AS n FROM sentences');
    expect(sentences.first['n'], 0);
  });

  test('recentConversations reflects new messages immediately', () async {
    await repo.ensureConversation('c1', title: 'first');
    await repo.appendMessage(conversationId: 'c1', message: user('u1', '你好'));

    final rows = await repo.recentConversations();
    expect(rows.single.id, 'c1');
    expect(rows.single.preview, '你好');
  });

  test('auto-title detection matches the repository placeholder shape', () {
    expect(isAutoTitle('对话 10-07 11:12'), isTrue);
    expect(isAutoTitle('朝 talk'), isFalse);
    expect(isAutoTitle(null), isFalse);
  });
}
