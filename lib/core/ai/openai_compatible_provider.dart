import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/structured_response_parser.dart';
import 'package:language_coach/core/config/app_config.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/network/api_client.dart';

/// Shared implementation for OpenAI-compatible `/chat/completions` endpoints
/// with Server-Sent-Events (SSE) streaming. Both [MiniMaxProvider] and
/// [DeepSeekProvider] subclass this and only differ in their [Endpoint]
/// (base URL, model, label).
abstract class OpenAiCompatibleProvider implements LlmProvider {
  OpenAiCompatibleProvider({
    required this.endpoint,
    required this.id,
    required this.apiKeyResolver,
    required this.apiClient,
    StructuredResponseParser? parser,
    this.systemPrompt = _defaultSystemPrompt,
  }) : parser = parser ?? const StructuredResponseParser();

  final ProviderEndpoint endpoint;
  @override
  final String id;

  /// Returns the API key to use for this request. Concrete providers wrap a
  /// [SecureKeyStore] (or a test fake) — the key is read lazily so callers
  /// can update storage between streams.
  final Future<String?> Function() apiKeyResolver;

  final ApiClient apiClient;
  final StructuredResponseParser parser;
  final String systemPrompt;

  static const String _defaultSystemPrompt = '''
You are "LanguageCoach", a multilingual tutor. Always respond with a single
JSON object (no prose, no markdown fences) matching this schema:

{
  "intent": "translation | conversation | grammarQuestion | correction | explanation | expressionHelp | roleplay | practice | vocabulary | pronunciation",
  "sourceLanguage": "<iso code, or 'auto'>",
  "targetLanguage": "<iso code>",
  "primary": "<main answer in the target language>",
  "chineseTranslation": "<complete Simplified-Chinese translation of primary>",
  "alternatives": ["<other acceptable answers>"],
  "explanation": "<short explanation in the user's input language>",
  "sentences": [{"id": "<stable id>", "text": "<one sentence>"}],
  "keywords": ["<key vocabulary>"]
}

Teaching requirements:
- Never leave "primary", "chineseTranslation", or "explanation" empty.
- "chineseTranslation" MUST give the complete meaning of "primary" in
  Simplified Chinese. If the target language is Chinese, copy "primary".
- "primary" and "sentences" MUST be written in the required target language
  named in the request metadata. The conversation history may be in another
  language; history NEVER overrides the metadata for the current turn.
- Treat a short word, name, or place (for example, "南京") as a vocabulary
  question: give its natural target-language form in "primary", then explain
  its meaning, pronunciation/transliteration, and one useful usage note in
  "explanation".
- For every other request, "explanation" must briefly teach in Simplified
  Chinese why the primary answer is natural or correct.
- Put at least one complete, speakable target-language example in "sentences".
''';

  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) async* {
    final key = await apiKeyResolver();
    if (key == null || key.isEmpty) {
      yield LlmEventError(const LlmError(
        LlmErrorKind.unauthorized,
        'API key not configured',
      ));
      return;
    }

    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': systemPrompt},
      ...context.map(_toOpenAiMessage),
      {'role': 'user', 'content': _composeUserPrompt(request)},
    ];

    final body = <String, Object?>{
      'model': endpoint.model,
      'messages': messages,
      'stream': true,
    };

    final url = '${endpoint.baseUrl}/chat/completions';

    Response<dynamic>? response;
    try {
      response = await apiClient.postStream(
        url: url,
        body: body,
        apiKey: key,
      );
    } on LlmError catch (e) {
      yield LlmEventError(e);
      return;
    } catch (e) {
      yield LlmEventError(LlmError(LlmErrorKind.unknown, e.toString()));
      return;
    }

    final responseData = response.data;
    final Stream<List<int>>? stream = switch (responseData) {
      ResponseBody body => body.stream,
      Stream<List<int>> bytes => bytes,
      _ => null,
    };
    if (stream == null) {
      yield LlmEventError(const LlmError(
        LlmErrorKind.format,
        'response body was not a stream',
      ));
      return;
    }

    final buffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    var emittedError = false;

    try {
      await for (final event in _decodeSse(stream)) {
        if (event.data.isEmpty) continue;
        if (event.data == '[DONE]') break;
        final parts = _extractDeltaParts(event.data);
        if (parts.content != null && parts.content!.isNotEmpty) {
          buffer.write(parts.content);
          yield LlmEventDelta(parts.content!);
        }
        // Reasoning tokens arrive separately from answer tokens on
        // thinking-enabled endpoints (DeepSeek-R1 puts the trace in
        // `delta.reasoning_content`). We stream them as their own event so
        // the UI can fold them away and so they never leak into `primary`.
        if (parts.reasoning != null && parts.reasoning!.isNotEmpty) {
          thinkingBuffer.write(parts.reasoning);
          yield LlmEventThinking(parts.reasoning!);
        }
        final errMsg = _extractError(event.data);
        if (errMsg != null) {
          emittedError = true;
          yield LlmEventError(LlmError(
            LlmErrorKind.unknown,
            errMsg,
            httpStatus: event.status,
          ));
          break;
        }
      }
    } on LlmError catch (e) {
      yield LlmEventError(e);
      return;
    } catch (e) {
      yield LlmEventError(LlmError(LlmErrorKind.unknown, e.toString()));
      return;
    }

    if (emittedError) return;

    final parsedResponse = parser.parse(
      buffer.toString(),
      intent: request.intent,
      targetLanguage: request.targetLanguage,
      thinkingFromCaller: thinkingBuffer.toString(),
    );
    // The parser already ignores the model's own `targetLanguage` field; this
    // is the belt-and-braces guarantee that whatever the payload claimed, the
    // turn answers in the language the client resolved.
    final response0 = _ensureTeachingExplanation(
      parsedResponse.copyWith(targetLanguage: request.targetLanguage.code),
      request,
    );
    final message = ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      response: response0,
      model: id,
    );
    yield LlmEventComplete(response0, message);
  }

  String _composeUserPrompt(CoachRequest request) {
    final switchNotice = request.languageChangedDuringConversation
        ? '- language switch: from this turn on, answer in the required target'
            ' language even if the earlier messages used another one\n'
        : '';
    return '''
Learner input: ${request.text}

Request metadata (follow this; do not copy it into the answer):
- detected intent: ${request.intent.name}
- required target language: ${request.targetLanguage.code} (${request.targetLanguage.label})
- chineseTranslation language: Simplified Chinese (required)
- explanation language: Simplified Chinese
$switchNotice''';
  }

  CoachResponse _ensureTeachingExplanation(
    CoachResponse response,
    CoachRequest request,
  ) {
    if (response.explanation.trim().isNotEmpty) return response;
    final answer = response.primary.trim();
    final explanation = answer.isEmpty
        ? '线上模型没有返回有效回答，请重新生成。'
        : '“${request.text.trim()}”对应的目标语言回答是“$answer”。'
            '线上模型本次未附带更详细的用法说明，请重新生成以获取完整解释。';
    return response.copyWith(explanation: explanation);
  }

  Map<String, Object?> _toOpenAiMessage(ChatMessage m) {
    final content = m.role == MessageRole.user
        ? m.sourceText ?? ''
        : m.response?.primary ?? '';
    return {
      'role': m.role == MessageRole.user ? 'user' : 'assistant',
      'content': content
    };
  }

  // Frame boundaries: the SSE spec terminates a frame with a blank line.
  // A "bare `\n` separated frames" workaround was tried and reverted — a
  // frame whose payload spans several `data:` lines and two frames joined by
  // a single `\n` are byte-for-byte identical, so no heuristic can tell them
  // apart and guessing would break the (spec-conforming, and actually
  // emitted by MiniMax / DeepSeek) multi-line case.
  Stream<_SseEvent> _decodeSse(Stream<List<int>> bytes) async* {
    final data = <String>[];
    int? status;
    await for (final line
        in utf8.decoder.bind(bytes).transform(const LineSplitter())) {
      if (line.startsWith('data:')) {
        data.add(line.substring(5).trimLeft());
      } else if (line.startsWith('status:')) {
        status = int.tryParse(line.substring(7).trim());
      } else if (line.isEmpty && data.isNotEmpty) {
        yield _SseEvent(data.join('\n'), status);
        data.clear();
        status = null;
      }
    }
    if (data.isNotEmpty) {
      yield _SseEvent(data.join('\n'), status);
    }
  }

  _DeltaParts _extractDeltaParts(String data) {
    try {
      final decoded = json.decode(data);
      if (decoded is Map) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map) {
            final delta = first['delta'];
            if (delta is Map) {
              final content = delta['content'];
              final reasoning = delta['reasoning_content'];
              return _DeltaParts(
                content: content is String ? content : null,
                reasoning: reasoning is String ? reasoning : null,
              );
            }
            // Some servers (DeepSeek legacy) emit `text` rather than
            // `delta.content`.
            final text = first['text'];
            if (text is String) return _DeltaParts(content: text);
          }
        }
      }
    } catch (e) {
      developer.log('sse parse failure',
          name: 'OpenAiCompatibleProvider', error: e);
    }
    return const _DeltaParts();
  }

  String? _extractError(String data) {
    try {
      final decoded = json.decode(data);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final message = error['message'];
          if (message is String) return message;
        }
      }
    } catch (_) {
      // non-JSON chunk — ignore
    }
    return null;
  }
}

class _SseEvent {
  const _SseEvent(this.data, this.status);
  final String data;
  final int? status;
}

/// Per-delta extraction. `content` is the visible answer chunk;
/// `reasoning` is the model's thinking trace (`delta.reasoning_content` on
/// DeepSeek-R1 and friends). Either or both can be null per event.
class _DeltaParts {
  const _DeltaParts({this.content, this.reasoning});
  final String? content;
  final String? reasoning;
}
