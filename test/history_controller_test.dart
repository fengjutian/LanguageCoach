import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/history/application/history_controller.dart';

ProviderContainer _container() {
  return ProviderContainer(
    overrides: [
      conversationRepositoryProvider
          .overrideWithValue(InMemoryConversationRepository()),
    ],
  );
}

void main() {
  test('history controller reads recent conversations', () async {
    final container = _container();
    addTearDown(container.dispose);
    final repo = container.read(conversationRepositoryProvider);
    await repo.ensureConversation('c1', title: 'first');
    await repo.appendMessage(
      conversationId: 'c1',
      message: ChatMessage(
        id: 'm1',
        role: MessageRole.user,
        createdAt: DateTime(2026),
        sourceText: 'hi',
      ),
    );
    await repo.ensureConversation('c2', title: 'second');

    final list = await container.read(historyControllerProvider.future);
    expect(list, hasLength(2));
    final titles = list.map((c) => c.title).toSet();
    expect(titles.contains('first'), isTrue);
    expect(titles.contains('second'), isTrue);
  });

  test('search query filters titles + message source', () async {
    final container = _container();
    addTearDown(container.dispose);
    final repo = container.read(conversationRepositoryProvider);
    await repo.ensureConversation('c1', title: '英语早餐');
    await repo.appendMessage(
      conversationId: 'c1',
      message: ChatMessage(
        id: 'm1',
        role: MessageRole.user,
        createdAt: DateTime(2026),
        sourceText: 'bread',
      ),
    );
    await repo.ensureConversation('c2', title: '日语');

    container.read(historySearchQueryProvider.notifier).state = '早餐';
    final list = await container.read(historyControllerProvider.future);
    expect(list.single.id, 'c1');
    expect(list.single.preview, 'bread');
  });

  test('deleteConversation removes it from the list', () async {
    final container = _container();
    addTearDown(container.dispose);
    final repo = container.read(conversationRepositoryProvider);
    await repo.ensureConversation('c1');
    await repo.ensureConversation('c2');
    await container
        .read(historyControllerProvider.notifier)
        .deleteConversation('c1');
    final list = await container.read(historyControllerProvider.future);
    expect(list.map((c) => c.id), ['c2']);
  });

  test('deleteAll wipes everything', () async {
    final container = _container();
    addTearDown(container.dispose);
    final repo = container.read(conversationRepositoryProvider);
    await repo.ensureConversation('c1');
    await repo.ensureConversation('c2');
    await container.read(historyControllerProvider.notifier).deleteAll();
    final list = await container.read(historyControllerProvider.future);
    expect(list, isEmpty);
  });
}
