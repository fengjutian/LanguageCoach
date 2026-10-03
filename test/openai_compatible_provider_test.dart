import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/minimax_provider.dart';
import 'package:language_coach/core/config/app_config.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/network/api_client.dart';

class _StreamingAdapter implements HttpClientAdapter {
  _StreamingAdapter([this.payload = _defaultPayload]);
  static const String _defaultPayload =
      'data: {"choices":[{"delta":{"content":"{\\"primary\\":\\"hello\\"}"}}]}\n\n'
      'data: [DONE]\n\n';

  final String payload;
  RequestOptions? lastRequest;
  List<int> lastRequestBody = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    lastRequestBody = await requestStream?.expand((chunk) => chunk).toList() ??
        const <int>[];
    return ResponseBody.fromBytes(
      utf8.encode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

MiniMaxProvider _providerWithAdapter(HttpClientAdapter adapter) {
  final dio = Dio()..httpClientAdapter = adapter;
  return MiniMaxProvider(
    endpoint: const ProviderEndpoint(
      baseUrl: 'https://example.test/v1',
      model: 'MiniMax-M3',
    ),
    apiKeyResolver: () async => 'test-key',
    apiClient: ApiClient(dio: dio),
  );
}

void main() {
  test('reads Dio ResponseBody as an SSE byte stream', () async {
    final provider = _providerWithAdapter(_StreamingAdapter());

    final events = await provider
        .generateStream(
          const CoachRequest(
            text: 'hello',
            intent: CoachIntent.conversation,
            targetLanguage: CoachLanguage.english,
          ),
          const <ChatMessage>[],
        )
        .toList();

    expect(events.whereType<LlmEventError>(), isEmpty);
    expect(events.whereType<LlmEventDelta>().single.text,
        '{"primary":"hello"}');
    expect(events.whereType<LlmEventComplete>(), hasLength(1));
  });

  test('sends Chinese input as UTF-8 JSON', () async {
    final adapter = _StreamingAdapter();
    final provider = _providerWithAdapter(adapter);

    await provider
        .generateStream(
          const CoachRequest(
            text: '你好，怎么说？😊',
            intent: CoachIntent.expressionHelp,
            targetLanguage: CoachLanguage.english,
          ),
          const <ChatMessage>[],
        )
        .drain<void>();

    expect(
      adapter.lastRequest?.headers[Headers.contentTypeHeader],
      'application/json; charset=utf-8',
    );
    final requestJson = jsonDecode(utf8.decode(adapter.lastRequestBody)) as Map;
    final messages = requestJson['messages'] as List;
    expect((messages.last as Map)['content'], '你好，怎么说？😊');
  });

  test('routes delta.reasoning_content into LlmEventThinking', () async {
    // Simulates DeepSeek-R1 style streaming where reasoning chunks arrive
    // interleaved with the actual answer chunks.
    const payload = 'data: {"choices":[{"delta":{"reasoning_content":"Let me think…"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"{\\"primary\\":\\"hello\\"}"}}]}\n\n'
        'data: [DONE]\n\n';
    final provider = _providerWithAdapter(_StreamingAdapter(payload));

    final events = await provider
        .generateStream(
          const CoachRequest(
            text: 'hello',
            intent: CoachIntent.conversation,
            targetLanguage: CoachLanguage.english,
          ),
          const <ChatMessage>[],
        )
        .toList();

    expect(events.whereType<LlmEventThinking>().single.text, 'Let me think…');
    expect(events.whereType<LlmEventDelta>().single.text,
        '{"primary":"hello"}');
    final complete = events.whereType<LlmEventComplete>().single;
    expect(complete.response.thinking, 'Let me think…');
    expect(complete.response.primary, 'hello');
  });

  test('null content and null reasoning do not yield empty events',
      () async {
    // DeepSeek emits `{content: null, reasoning_content: null}` mid-stream
    // when switching phases. Those events must be silently skipped.
    const payload = 'data: {"choices":[{"delta":{"content":null,"reasoning_content":null}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
        'data: [DONE]\n\n';
    final provider = _providerWithAdapter(_StreamingAdapter(payload));

    final events = await provider
        .generateStream(
          const CoachRequest(
            text: 'hi',
            intent: CoachIntent.conversation,
            targetLanguage: CoachLanguage.english,
          ),
          const <ChatMessage>[],
        )
        .toList();

    expect(events.whereType<LlmEventDelta>().single.text, 'hi');
    expect(events.whereType<LlmEventThinking>(), isEmpty);
    final complete = events.whereType<LlmEventComplete>().single;
    expect(complete.response.thinking, '');
    expect(complete.response.primary, 'hi');
  });
}
