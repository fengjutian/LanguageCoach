import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/models/conversation.dart';

/// Storage contract for conversation + [ChatMessage] persistence. The chat
/// controller owns one conversation id at a time and uses these primitives to
/// load, extend and regenerate turns; widgets never touch the repository.
abstract interface class ConversationRepository {
  /// Idempotent create-or-repair. Kept for the first-message path where the
  /// controller already has a lazy draft id it wants materialised.
  Future<void> ensureConversation(
    String id, {
    String? title,
    CoachLanguage? preferredLanguage,
    CoachLanguage? targetLanguage,
    DateTime? createdAt,
  });

  Future<void> updateTitle(String conversationId, String title);

  Future<Conversation?> getConversation(String conversationId);

  Future<List<ChatMessage>> messagesFor(String conversationId);

  Future<String> appendMessage({
    required String conversationId,
    required ChatMessage message,
  });

  /// Drop every message that belongs to the assistant turn following
  /// [userMessageId], then insert [assistant] as the replacement. Regenerate
  /// must not grow the transcript — the old failed/partial answer and its
  /// sentences have to disappear from SQLite as well as from the UI.
  Future<void> replaceAssistantTurn({
    required String conversationId,
    required String userMessageId,
    required ChatMessage assistant,
  });

  /// Update only the per-conversation target language. Must not touch
  /// `created_at` nor bump `updated_at` into a reorder storm — callers refresh
  /// the history list explicitly instead.
  Future<void> updateConversationLanguage(
    String conversationId,
    CoachLanguage language,
  );

  Future<void> deleteConversation(String conversationId);

  Future<void> deleteAllConversations();

  Future<List<({String id, String preview, DateTime updatedAt})>>
      recentConversations({int limit = 50, String? query});
}

/// Read/write contract for [AppSettings]. Concrete implementation reads from
/// SQLite and is written by [SettingsController] through a serialised queue.
abstract interface class SettingsRepository {
  Future<Map<Object?, Object?>> loadRaw();

  Future<void> saveRaw(Map<Object?, Object?> raw);
}
