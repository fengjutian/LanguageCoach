import 'package:flutter/foundation.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Load status for the transcript pane. [initial] is the pre-hydration
/// window, [error] carries a recoverable failure (e.g. the conversation id in
/// `lastConversationId` no longer exists).
enum ChatLoadStatus { initial, loading, ready, error }

/// Single source of truth for "what conversation am I looking at".
///
/// Every field here is owned by `ChatController`. Widgets watch this and never
/// keep their own copy of the conversation id, the message list or the
/// streaming flag — that duplication is what let a stale reply from
/// conversation A land in conversation B.
@immutable
class ChatState {
  const ChatState({
    required this.conversationId,
    required this.isDraft,
    required this.conversationLanguage,
    required this.messages,
    required this.loadStatus,
    required this.isStreaming,
    required this.epoch,
    this.streamingMessageId,
    this.lastUserMessageId,
    this.lastTurnLanguage,
    this.error,
  });

  /// Stable for the lifetime of the conversation. A draft id exists in memory
  /// only until the first message is persisted.
  final String conversationId;

  /// True when no row exists in `conversations` yet. New conversations start
  /// as drafts so repeatedly tapping "new" does not litter the database.
  final bool isDraft;

  /// Per-conversation learning target. Seeded from the global default for new
  /// conversations, restored from the DB row when opening history.
  final CoachLanguage conversationLanguage;

  final List<ChatMessage> messages;
  final ChatLoadStatus loadStatus;
  final bool isStreaming;

  /// Assistant bubble currently receiving tokens, if any.
  final String? streamingMessageId;

  /// Anchor for regenerate — the user message whose answer we replace.
  final String? lastUserMessageId;

  /// Language actually used by the in-flight / last turn. The UI shows this so
  /// an explicit "用英语怎么说" is visibly different from the selector value.
  final CoachLanguage? lastTurnLanguage;

  /// Recoverable failure string; the transcript stays empty rather than
  /// showing a previous conversation's messages.
  final String? error;

  /// Bumped on every conversation switch / new / delete. Async callbacks
  /// compare against their captured epoch before touching state.
  final int epoch;

  bool get canSend => !isStreaming && loadStatus != ChatLoadStatus.loading;

  ChatState copyWith({
    String? conversationId,
    bool? isDraft,
    CoachLanguage? conversationLanguage,
    List<ChatMessage>? messages,
    ChatLoadStatus? loadStatus,
    bool? isStreaming,
    String? streamingMessageId,
    bool clearStreamingMessageId = false,
    String? lastUserMessageId,
    bool clearLastUserMessageId = false,
    CoachLanguage? lastTurnLanguage,
    bool clearLastTurnLanguage = false,
    String? error,
    bool clearError = false,
    int? epoch,
  }) {
    return ChatState(
      conversationId: conversationId ?? this.conversationId,
      isDraft: isDraft ?? this.isDraft,
      conversationLanguage: conversationLanguage ?? this.conversationLanguage,
      messages: messages ?? this.messages,
      loadStatus: loadStatus ?? this.loadStatus,
      isStreaming: isStreaming ?? this.isStreaming,
      streamingMessageId: clearStreamingMessageId
          ? null
          : (streamingMessageId ?? this.streamingMessageId),
      lastUserMessageId: clearLastUserMessageId
          ? null
          : (lastUserMessageId ?? this.lastUserMessageId),
      lastTurnLanguage: clearLastTurnLanguage
          ? null
          : (lastTurnLanguage ?? this.lastTurnLanguage),
      error: clearError ? null : (error ?? this.error),
      epoch: epoch ?? this.epoch,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChatState &&
      other.conversationId == conversationId &&
      other.isDraft == isDraft &&
      other.conversationLanguage == conversationLanguage &&
      other.loadStatus == loadStatus &&
      other.isStreaming == isStreaming &&
      other.streamingMessageId == streamingMessageId &&
      other.lastUserMessageId == lastUserMessageId &&
      other.lastTurnLanguage == lastTurnLanguage &&
      other.error == error &&
      other.epoch == epoch &&
      listEquals(other.messages, messages);

  @override
  int get hashCode => Object.hash(
        conversationId,
        isDraft,
        conversationLanguage,
        loadStatus,
        isStreaming,
        streamingMessageId,
        lastUserMessageId,
        lastTurnLanguage,
        error,
        epoch,
        Object.hashAll(messages),
      );
}
