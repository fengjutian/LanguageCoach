import 'dart:convert';

import '../models/chat_models.dart';

/// Parses the accumulated raw text emitted by an LLM streaming response into
/// a [CoachResponse]. The contract is deliberately forgiving:
///
///   * Surrounding Markdown ```json ... ``` blocks are stripped.
///   * If the inner text isn't a JSON object, the whole string is treated as
///     `primary` with no structured metadata.
///   * If the inner text is JSON but the `sentences` field is missing or
///     empty, the parser auto-populates one from `primary` so the audio /
///     UI layer never sees an empty sentence list.
///
/// The parser does not log or echo the raw text; if you need diagnostics,
/// pipe the raw bytes into your own sink first.
class StructuredResponseParser {
  const StructuredResponseParser();

  CoachResponse parse(
    String raw, {
    required CoachIntent intent,
    required CoachLanguage targetLanguage,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return _synthesize(
        primary: '',
        intent: intent,
        targetLanguage: targetLanguage,
      );
    }

    final jsonBody = _stripFence(trimmed);

    final parsed = _tryParseJsonObject(jsonBody);
    if (parsed == null) {
      // Not a JSON payload at all — treat the whole text as `primary`.
      return _synthesize(
        primary: trimmed,
        intent: intent,
        targetLanguage: targetLanguage,
      );
    }

    final merged = <String, Object?>{
      ...parsed,
      'intent': parsed['intent'] ?? intent.name,
      'targetLanguage': parsed['targetLanguage'] ?? targetLanguage.code,
    };
    return CoachResponse.fromJson(merged);
  }

  CoachResponse _synthesize({
    required String primary,
    required CoachIntent intent,
    required CoachLanguage targetLanguage,
  }) {
    final sentences = <CoachSentence>[];
    if (primary.isNotEmpty) {
      sentences.add(CoachSentence(id: 'auto_1', text: primary));
    }
    return CoachResponse(
      intent: intent,
      sourceLanguage: 'auto',
      targetLanguage: targetLanguage.code,
      primary: primary,
      explanation: '',
      sentences: List.unmodifiable(sentences),
    );
  }

  /// Removes Markdown ```json ... ``` fences and any leading/trailing prose.
  /// Falls through unchanged if no fence is present.
  String _stripFence(String input) {
    const fenceStart = '```';
    if (!input.startsWith(fenceStart) && !input.contains('\n```')) {
      return input;
    }
    var cursor = input.indexOf(fenceStart);
    var stripped = input.substring(cursor + fenceStart.length);
    // Optional `json` annotation right after the fence.
    if (stripped.startsWith('json')) {
      stripped = stripped.substring(4);
    }
    stripped = stripped.trimLeft();
    final endIndex = stripped.lastIndexOf('```');
    if (endIndex >= 0) {
      stripped = stripped.substring(0, endIndex);
    }
    return stripped.trim();
  }

  Map<String, Object?>? _tryParseJsonObject(String input) {
    try {
      final dynamic decoded = json.decode(input);
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
    } catch (_) {
      // fall through — treat as non-JSON
    }
    return null;
  }
}