import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';

void main() {
  group('InMemoryConversationRepository', () {
    test('ensureConversation + append + read round-trip', () async {
      final repo = InMemoryConversationRepository();
      await repo.ensureConversation('c1');
      await repo.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: 'm1',
          role: MessageRole.user,
          createdAt: DateTime(2026),
          sourceText: 'hello',
        ),
      );
      final all = await repo.messagesFor('c1');
      expect(all, hasLength(1));
      expect(all.first.sourceText, 'hello');
    });

    test('append assistant message preserves response + sentences', () async {
      final repo = InMemoryConversationRepository();
      await repo.ensureConversation('c1');
      await repo.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: 'a1',
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          response: CoachResponse(
            intent: CoachIntent.translation,
            sourceLanguage: 'en',
            targetLanguage: 'zh',
            primary: '你好',
            explanation: 'greeting',
            sentences: [
              const CoachSentence(id: 's1', text: '你好'),
            ],
          ),
        ),
      );
      final all = await repo.messagesFor('c1');
      expect(all.single.response?.primary, '你好');
      expect(all.single.response?.sentences.single.text, '你好');
    });

    test('deleteConversation removes all messages for that id', () async {
      final repo = InMemoryConversationRepository();
      await repo.ensureConversation('c1');
      await repo.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: 'm1',
          role: MessageRole.user,
          createdAt: DateTime(2026),
          sourceText: 'a',
        ),
      );
      await repo.deleteConversation('c1');
      expect(await repo.messagesFor('c1'), isEmpty);
    });

    test('recentConversations supports substring search', () async {
      final repo = InMemoryConversationRepository();
      await repo.ensureConversation('c1', title: '英语早餐');
      await repo.appendMessage(
        conversationId: 'c1',
        message: ChatMessage(
          id: 'm1',
          role: MessageRole.user,
          createdAt: DateTime(2026),
          sourceText: 'bread and butter',
        ),
      );
      await repo.ensureConversation('c2', title: '日语');
      final hits = await repo.recentConversations(query: '早餐');
      expect(hits.single.id, 'c1');
      expect(hits.single.preview, 'bread and butter');
    });

    test('deleteAllConversations empties the store', () async {
      final repo = InMemoryConversationRepository();
      await repo.ensureConversation('c1');
      await repo.ensureConversation('c2');
      await repo.deleteAllConversations();
      expect(await repo.recentConversations(), isEmpty);
    });

    test('updateTitle persists', () async {
      final repo = InMemoryConversationRepository();
      await repo.ensureConversation('c1', title: 'default');
      await repo.updateTitle('c1', 'manual title');
      final meta = await repo.getConversation('c1');
      expect(meta?.title, 'manual title');
    });
  });

  group('InMemorySettingsRepository', () {
    test('round-trip', () async {
      final repo = InMemorySettingsRepository();
      await repo.saveRaw(<String, Object?>{
        'preferredLanguage': 'french',
        'speechSpeed': 1.25,
      });
      final raw = await repo.loadRaw();
      expect(raw['preferredLanguage'], 'french');
      expect(raw['speechSpeed'], 1.25);
    });
  });

  // Sanity: AppSettings integration with the in-memory settings store.
  test('AppSettings round-trips via repository', () async {
    final repo = InMemorySettingsRepository();
    const settings = AppSettings(
      preferredLanguage: CoachLanguage.korean,
      provider: AiProvider.miniMax,
      speechSpeed: 0.85,
      autoPlay: true,
      saveHistory: false,
      lastConversationId: 'c_x',
    );
    await repo.saveRaw(settings.toJson());
    final back = AppSettings.fromJson(await repo.loadRaw());
    expect(back.preferredLanguage, CoachLanguage.korean);
    expect(back.provider, AiProvider.miniMax);
    expect(back.speechSpeed, 0.85);
    expect(back.autoPlay, isTrue);
    expect(back.saveHistory, isFalse);
    expect(back.lastConversationId, 'c_x');
  });
}
