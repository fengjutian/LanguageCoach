import 'package:language_coach/core/models/chat_models.dart';

/// Storage contract for [ChatMessage] persistence. Implementations land in
/// P0-3 (SQLite-backed). Tests inject an in-memory fake; widgets never
/// construct the implementation directly.
abstract interface class ConversationRepository {
  Future<List<ChatMessage>> messagesFor(String conversationId);

  Future<String> appendMessage({
    required String conversationId,
    required ChatMessage message,
  });

  Future<void> deleteConversation(String conversationId);

  Future<List<({String id, String preview, DateTime updatedAt})>>
      recentConversations({int limit = 50});
}

/// Read/write contract for [AppSettings]. Concrete implementation reads from
/// SQLite in P0-3 and currently lives as in-memory state via Riverpod.
abstract interface class SettingsRepository {
  Future<Map<Object?, Object?>> loadRaw();

  Future<void> saveRaw(Map<Object?, Object?> raw);
}
