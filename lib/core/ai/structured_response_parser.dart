import 'dart:convert';

import '../models/app_settings.dart';
import '../models/chat_models.dart';

/// Parses the accumulated raw text emitted by an LLM streaming response into
/// a [CoachResponse]. The contract is deliberately forgiving:
///
///   * Surrounding Markdown ```json ... ``` blocks are stripped.
///   * Inline reasoning blocks (`<think>...</think>`, `<reasoning>...`,
///     `<<<REASONING>>>...<<<END>>>`, `<|thinking|>...<|/thinking|>`,
///     `【思考】...【/思考】`) are removed from the answer surface and
///     surfaced via [CoachResponse.thinking]. If the caller already
///     accumulated a thinking stream from SSE `delta.reasoning_content`,
///     [thinkingFromCaller] is preferred and merged.
///   * If the inner text isn't a JSON object, the cleaned (thinking-stripped)
///     string is treated as `primary` with no structured metadata.
///   * If the inner text is JSON but the `sentences` field is missing or
///     empty, the parser auto-populates one from `primary` so the audio /
///     UI layer never sees an empty sentence list.
///
/// The parser does not log or echo the raw text; if you need diagnostics,
/// pipe the raw bytes into your own sink first.
class StructuredResponseParser {
  const StructuredResponseParser();

  /// Matches every thinking wrapper used by the open-source / hosted
  /// reasoning models we care about. Group 1 is the captured inner content;
  /// outer tag is stripped before JSON parse so `primary` stays clean.
  static final RegExp _thinkingBlock = RegExp(
    r'<think>([\s\S]*?)<\/think>'
    r'|<reasoning>([\s\S]*?)<\/reasoning>'
    r'|<<<REASONING>>>([\s\S]*?)<<<END>>>'
    r'|<\|begin_of_thinking\|>([\s\S]*?)<\|end_of_thinking\|>'
    r'|<\|thinking\|>([\s\S]*?)<\|\/thinking\|>'
    r'|【思考】([\s\S]*?)【\/思考】',
    caseSensitive: false,
  );

  CoachResponse parse(
    String raw, {
    required CoachIntent intent,
    required CoachLanguage targetLanguage,
    String thinkingFromCaller = '',
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return _synthesize(
        primary: '',
        thinking: thinkingFromCaller,
        intent: intent,
        targetLanguage: targetLanguage,
      );
    }

    final extraction = _splitThinking(trimmed);
    final jsonBody = _stripFence(extraction.cleaned);

    // Resolve thinking with the same priority regardless of whether the
    // payload parsed as JSON: inline `<think>` block > caller's SSE
    // `reasoning_content` stream > JSON `thinking` field. The non-JSON
    // branch below uses the same priority by re-reading these three sources.
    String resolveThinking(Map<Object?, Object?>? parsed) {
      if (extraction.thinking.isNotEmpty) return extraction.thinking;
      if (thinkingFromCaller.isNotEmpty) return thinkingFromCaller;
      final fromJson = parsed?['thinking']?.toString();
      if (fromJson != null && fromJson.isNotEmpty) return fromJson;
      return '';
    }

    final parsed = _tryParseJsonObject(jsonBody);
    if (parsed == null) {
      // Not a JSON payload at all — treat the cleaned text as `primary`.
      return _synthesize(
        primary: jsonBody.isEmpty ? trimmed : jsonBody,
        thinking: resolveThinking(null),
        intent: intent,
        targetLanguage: targetLanguage,
      );
    }

    final merged = <String, Object?>{
      ...parsed,
      // The client already resolved intent and the target language *before*
      // the request went out. Letting the model echo its own `intent` /
      // `targetLanguage` field means a hallucinated value silently reroutes
      // the TTS voice and the answer label, so the request wins outright.
      'intent': intent.name,
      'targetLanguage': targetLanguage.code,
      'thinking': resolveThinking(parsed),
    };
    return CoachResponse.fromJson(merged);
  }

  CoachResponse _synthesize({
    required String primary,
    required CoachIntent intent,
    required CoachLanguage targetLanguage,
    String thinking = '',
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
      thinking: thinking,
      explanation: '',
      sentences: List.unmodifiable(sentences),
    );
  }

  /// Removes Markdown ```json ... ``` fences and any leading/trailing prose.
  /// Falls through unchanged if no fence is present.
  String _stripFence(String input) {
    const fenceStart = '```';
    final cursor = input.indexOf(fenceStart);
    if (cursor < 0) return input;
    var stripped = input.substring(cursor + fenceStart.length);
    // Optional language annotation right after the fence. Models write
    // `json`, `JSON` and `Json` interchangeably, and a case-sensitive
    // `startsWith('json')` glued `JSON` onto the payload so the decode failed
    // and the backticks ended up inside `primary`.
    final annotation = RegExp(r'^[A-Za-z0-9_+-]+').firstMatch(stripped);
    if (annotation != null) {
      stripped = stripped.substring(annotation.end);
    }
    stripped = stripped.trimLeft();
    final endIndex = stripped.lastIndexOf('```');
    if (endIndex >= 0) {
      stripped = stripped.substring(0, endIndex);
    }
    return stripped.trim();
  }

  /// Splits [input] into (a) concatenated thinking text and (b) the original
  /// text with all thinking blocks removed. Tolerant of nested/unclosed
  /// blocks — anything that doesn't close is left in [ThinkingExtraction.cleaned]
  /// so the user still sees something rather than a silent failure.
  ThinkingExtraction _splitThinking(String input) {
    if (input.isEmpty) return const ThinkingExtraction('', '');
    final parts = <String>[];
    for (final m in _thinkingBlock.allMatches(input)) {
      for (var i = 1; i <= m.groupCount; i++) {
        final inner = m.group(i);
        if (inner != null) {
          final t = inner.trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
    }
    if (parts.isEmpty) return ThinkingExtraction('', input);
    final cleaned = input.replaceAll(_thinkingBlock, '').trim();
    return ThinkingExtraction(parts.join('\n\n'), cleaned);
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

/// Result of pulling reasoning traces out of a raw assistant message.
class ThinkingExtraction {
  const ThinkingExtraction(this.thinking, this.cleaned);
  final String thinking;
  final String cleaned;
}
