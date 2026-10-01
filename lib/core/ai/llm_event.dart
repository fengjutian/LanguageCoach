import '../models/chat_models.dart';
import '../network/api_client.dart';

/// Streaming events emitted by an [LlmProvider]. The chat UI consumes these
/// to render partial text, finalise a message, or surface an error card.
sealed class LlmEvent {
  const LlmEvent();
}

/// Partial content delta. Multiple deltas may arrive before
/// [LlmEventComplete]; UI is expected to concatenate them into the same
/// streaming bubble.
class LlmEventDelta extends LlmEvent {
  const LlmEventDelta(this.text);
  final String text;
}

/// Terminal event — the structured [CoachResponse] has been assembled. The
/// stream will not emit any more deltas after [LlmEventComplete].
class LlmEventComplete extends LlmEvent {
  const LlmEventComplete(this.response, this.assistantMessage);
  final CoachResponse response;

  /// Final wrapped message (carries id, role, createdAt, model). The chat
  /// page appends this verbatim once the stream ends.
  final ChatMessage assistantMessage;
}

/// Terminal event — the request failed. Includes enough metadata for the
/// UI to render a localised error card and a retry button.
class LlmEventError extends LlmEvent {
  const LlmEventError(this.error);
  final LlmError error;
}