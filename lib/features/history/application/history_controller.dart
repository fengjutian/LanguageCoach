import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database_provider.dart';

typedef ConversationSummary = ({
  String id,
  String title,
  String preview,
  DateTime updatedAt,
});

final historySearchQueryProvider = StateProvider<String>((_) => '');

final historyControllerProvider =
    AsyncNotifierProvider<HistoryController, List<ConversationSummary>>(
  HistoryController.new,
);

class HistoryController extends AsyncNotifier<List<ConversationSummary>> {
  @override
  Future<List<ConversationSummary>> build() async {
    final query = ref.watch(historySearchQueryProvider);
    final repo = ref.read(conversationRepositoryProvider);
    final raw = await repo.recentConversations(query: query);
    final summaries = <ConversationSummary>[];
    for (final row in raw) {
      final meta = await repo.getConversation(row.id);
      summaries.add((
        id: row.id,
        title: meta?.title ?? '对话',
        preview: row.preview,
        updatedAt: row.updatedAt,
      ));
    }
    return summaries;
  }

  Future<void> deleteConversation(String conversationId) async {
    await ref
        .read(conversationRepositoryProvider)
        .deleteConversation(conversationId);
    ref.invalidateSelf();
  }

  Future<void> deleteAll() async {
    await ref.read(conversationRepositoryProvider).deleteAllConversations();
    ref.invalidateSelf();
  }
}
