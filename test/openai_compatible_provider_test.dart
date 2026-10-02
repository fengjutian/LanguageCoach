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
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    const payload =
        'data: {"choices":[{"delta":{"content":"{\\"primary\\":\\"hello\\"}"}}]}\n\n'
        'data: [DONE]\n\n';
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

void main() {
  test('reads Dio ResponseBody as an SSE byte stream', () async {
    final dio = Dio()..httpClientAdapter = _StreamingAdapter();
    final provider = MiniMaxProvider(
      endpoint: const ProviderEndpoint(
        baseUrl: 'https://example.test/v1',
        model: 'MiniMax-M3',
      ),
      apiKeyResolver: () async => 'test-key',
      apiClient: ApiClient(dio: dio),
    );

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
}
