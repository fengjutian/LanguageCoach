import 'dart:convert';
import 'dart:typed_data';

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
  _StreamingAdapter([this.payload = _defaultPayload, this.chunks]);
  static const String _defaultPayload =
      'data: {"choices":[{"delta":{"content":"{\\"primary\\":\\"hello\\"}"}}]}\n\n'
      'data: [DONE]\n\n';

  final String payload;
  final List<List<int>>? chunks;
  RequestOptions? lastRequest;
  List<int> lastRequestBody = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    lastRequestBody =
        await requestStream?.expand((chunk) => chunk).toList() ?? const <int>[];
    return ResponseBody(
      Stream<Uint8List>.fromIterable(
        (chunks ?? <List<int>>[utf8.encode(payload)]).map(Uint8List.fromList),
      ),
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

    final events = await provider.generateStream(
      const CoachRequest(
        text: 'hello',
        intent: CoachIntent.conversation,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).toList();

    expect(
      events.whereType<LlmEventError>().map((event) => event.error.message),
      isEmpty,
    );
    expect(
        events.whereType<LlmEventDelta>().single.text, '{"primary":"hello"}');
    expect(events.whereType<LlmEventComplete>(), hasLength(1));
  });

  test('parses an SSE event split across arbitrary network chunks', () async {
    final bytes = utf8.encode(_StreamingAdapter._defaultPayload);
    final provider = _providerWithAdapter(_StreamingAdapter(
      _StreamingAdapter._defaultPayload,
      <List<int>>[
        bytes.sublist(0, 9),
        bytes.sublist(9, 31),
        bytes.sublist(31),
      ],
    ));

    final events = await provider.generateStream(
      const CoachRequest(
        text: 'hello',
        intent: CoachIntent.conversation,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).toList();

    expect(events.whereType<LlmEventError>(), isEmpty);
    expect(
        events.whereType<LlmEventDelta>().single.text, '{"primary":"hello"}');
    expect(events.whereType<LlmEventComplete>(), hasLength(1));
  });

  test('joins a multi-line data payload terminated by a blank line', () async {
    // Guards the SSE framing: a frame whose payload spans several `data:`
    // lines must stay joined with `\n`. A "treat every `data:` line as a new
    // frame" workaround was tried and reverted — it is byte-for-byte
    // indistinguishable from two frames joined by a bare `\n`, and it broke
    // this spec-conforming case.
    const payload = 'data: {"choices":[{"delta":\n'
        'data: {"content":"{\\"primary\\":\\"ok\\"}"}}]}\n'
        '\n'
        'data: [DONE]\n\n';
    final provider = _providerWithAdapter(_StreamingAdapter(payload));

    final events = await provider.generateStream(
      const CoachRequest(
        text: 'hello',
        intent: CoachIntent.conversation,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).toList();

    expect(events.whereType<LlmEventError>(), isEmpty);
    expect(events.whereType<LlmEventDelta>().single.text, '{"primary":"ok"}');
  });

  test('sends Chinese input as UTF-8 JSON', () async {
    final adapter = _StreamingAdapter();
    final provider = _providerWithAdapter(adapter);

    await provider.generateStream(
      const CoachRequest(
        text: '你好，怎么说？😊',
        intent: CoachIntent.expressionHelp,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).drain<void>();

    expect(
      adapter.lastRequest?.headers[Headers.contentTypeHeader],
      'application/json; charset=utf-8',
    );
    final requestJson = jsonDecode(utf8.decode(adapter.lastRequestBody)) as Map;
    final messages = requestJson['messages'] as List;
    expect(
      (messages.first as Map)['content'],
      contains('Never leave "primary" or "explanation" empty'),
    );
    final userPrompt = (messages.last as Map)['content'] as String;
    expect(userPrompt, contains('Learner input: 你好，怎么说？😊'));
    expect(userPrompt, contains('detected intent: expressionHelp'));
    expect(userPrompt, contains('required target language: en'));
  });

  test('fills a visible explanation when the online model omits it', () async {
    const payload =
        'data: {"choices":[{"delta":{"content":"{\\"primary\\":\\"Nanjing\\"}"}}]}\n\n'
        'data: [DONE]\n\n';
    final provider = _providerWithAdapter(_StreamingAdapter(payload));

    final events = await provider.generateStream(
      const CoachRequest(
        text: '南京',
        intent: CoachIntent.vocabulary,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).toList();

    final response = events.whereType<LlmEventComplete>().single.response;
    expect(response.primary, 'Nanjing');
    expect(response.explanation, isNotEmpty);
    expect(response.explanation, contains('南京'));
    expect(response.explanation, contains('Nanjing'));
  });

  test('routes delta.reasoning_content into LlmEventThinking', () async {
    // Simulates DeepSeek-R1 style streaming where reasoning chunks arrive
    // interleaved with the actual answer chunks.
    const payload =
        'data: {"choices":[{"delta":{"reasoning_content":"Let me think…"}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"{\\"primary\\":\\"hello\\"}"}}]}\n\n'
        'data: [DONE]\n\n';
    final provider = _providerWithAdapter(_StreamingAdapter(payload));

    final events = await provider.generateStream(
      const CoachRequest(
        text: 'hello',
        intent: CoachIntent.conversation,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).toList();

    expect(events.whereType<LlmEventThinking>().single.text, 'Let me think…');
    expect(
        events.whereType<LlmEventDelta>().single.text, '{"primary":"hello"}');
    final complete = events.whereType<LlmEventComplete>().single;
    expect(complete.response.thinking, 'Let me think…');
    expect(complete.response.primary, 'hello');
  });

  test('null content and null reasoning do not yield empty events', () async {
    // DeepSeek emits `{content: null, reasoning_content: null}` mid-stream
    // when switching phases. Those events must be silently skipped.
    const payload =
        'data: {"choices":[{"delta":{"content":null,"reasoning_content":null}}]}\n\n'
        'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
        'data: [DONE]\n\n';
    final provider = _providerWithAdapter(_StreamingAdapter(payload));

    final events = await provider.generateStream(
      const CoachRequest(
        text: 'hi',
        intent: CoachIntent.conversation,
        targetLanguage: CoachLanguage.english,
      ),
      const <ChatMessage>[],
    ).toList();

    expect(events.whereType<LlmEventDelta>().single.text, 'hi');
    expect(events.whereType<LlmEventThinking>(), isEmpty);
    final complete = events.whereType<LlmEventComplete>().single;
    expect(complete.response.thinking, '');
    expect(complete.response.primary, 'hi');
  });
}
