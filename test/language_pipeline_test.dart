import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/minimax_provider.dart';
import 'package:language_coach/core/ai/structured_response_parser.dart';
import 'package:language_coach/core/config/app_config.dart';
import 'package:language_coach/core/language/target_language_resolver.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/network/api_client.dart';

/// Feeds a canned SSE payload to the provider and captures the request body.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.payload);

  final String payload;
  List<int> lastBody = const [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastBody = await requestStream?.expand((c) => c).toList() ?? const <int>[];
    return ResponseBody(
      Stream<Uint8List>.value(Uint8List.fromList(utf8.encode(payload))),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

MiniMaxProvider _provider(_Adapter adapter) {
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

String _ssePayload(String content) => 'data: ${json.encode({
          'choices': [
            {
              'delta': {'content': content}
            }
          ]
        })}\n\n'
    'data: [DONE]\n\n';

List<Map<String, Object?>> _sentMessages(List<int> body) {
  final decoded = jsonDecode(utf8.decode(body)) as Map<String, Object?>;
  return (decoded['messages'] as List).cast<Map<String, Object?>>();
}

ChatMessage _assistant(String id, String text, {String language = 'en'}) =>
    ChatMessage(
      id: id,
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      status: ChatMessageStatus.completed,
      response: CoachResponse(
        intent: CoachIntent.conversation,
        sourceLanguage: 'auto',
        targetLanguage: language,
        primary: text,
        explanation: '',
        sentences: <CoachSentence>[CoachSentence(id: 's1', text: text)],
      ),
    );

void main() {
  group('client-side language is authoritative', () {
    const parser = StructuredResponseParser();

    test('a model-claimed target language never overrides the request', () {
      const raw = '{"targetLanguage":"en","primary":"今日は雨です"}';
      final r = parser.parse(
        raw,
        intent: CoachIntent.conversation,
        targetLanguage: CoachLanguage.japanese,
      );
      expect(r.targetLanguage, 'ja');
    });

    test('a model-claimed intent never overrides the request', () {
      const raw = '{"intent":"roleplay","primary":"x"}';
      final r = parser.parse(
        raw,
        intent: CoachIntent.correction,
        targetLanguage: CoachLanguage.english,
      );
      expect(r.intent, CoachIntent.correction);
    });

    test('missing fields still fall back to the request values', () {
      final r = parser.parse(
        '{"primary":"hi"}',
        intent: CoachIntent.vocabulary,
        targetLanguage: CoachLanguage.german,
      );
      expect(r.intent, CoachIntent.vocabulary);
      expect(r.targetLanguage, 'de');
    });

    test('the online provider forces the request language on the response',
        () async {
      // The model answers "en" while the request demanded "ja" — the exact
      // case that used to display and speak an English answer for a Japanese
      // exercise.
      final adapter = _Adapter(_ssePayload(
        '{"targetLanguage":"en","primary":"It is raining","explanation":"x"}',
      ));
      final provider = _provider(adapter);

      final events = await provider.generateStream(
        const CoachRequest(
          text: '今天下雨吗',
          intent: CoachIntent.conversation,
          targetLanguage: CoachLanguage.japanese,
        ),
        const <ChatMessage>[],
      ).toList();

      final complete = events.whereType<LlmEventComplete>().single;
      expect(complete.response.targetLanguage, 'ja');
      expect(complete.assistantMessage.response?.targetLanguage, 'ja');
    });

    test('the prompt names both the code and the readable language', () async {
      final adapter = _Adapter(_ssePayload('{"primary":"ok"}'));
      final provider = _provider(adapter);

      await provider.generateStream(
        const CoachRequest(
          text: '今天下雨吗',
          intent: CoachIntent.conversation,
          targetLanguage: CoachLanguage.japanese,
        ),
        const <ChatMessage>[],
      ).drain<void>();

      final messages = _sentMessages(adapter.lastBody);
      final userPrompt = messages.last['content'] as String;
      expect(userPrompt, contains('required target language: ja'));
      expect(userPrompt, contains(CoachLanguage.japanese.label));
      final systemPrompt = messages.first['content'] as String;
      expect(
        systemPrompt,
        contains('history NEVER overrides the metadata for the current turn'),
      );
    });

    test('a mid-conversation language switch is called out in the prompt',
        () async {
      final adapter = _Adapter(_ssePayload('{"primary":"ok"}'));
      final provider = _provider(adapter);

      await provider.generateStream(
        const CoachRequest(
          text: 'ありがとう',
          intent: CoachIntent.conversation,
          targetLanguage: CoachLanguage.english,
          languageChangedDuringConversation: true,
        ),
        <ChatMessage>[_assistant('a1', '今日は晴れ', language: 'ja')],
      ).drain<void>();

      final messages = _sentMessages(adapter.lastBody);
      expect(
        (messages.last['content'] as String),
        contains('language switch'),
      );
    });

    test('only eligible history turns reach the wire', () async {
      final adapter = _Adapter(_ssePayload('{"primary":"ok"}'));
      final provider = _provider(adapter);
      final pendingPlaceholder = ChatMessage(
        id: 'a_pending',
        role: MessageRole.assistant,
        createdAt: DateTime(2026),
        status: ChatMessageStatus.streaming,
      );

      await provider.generateStream(
        const CoachRequest(
          text: 'next',
          intent: CoachIntent.conversation,
          targetLanguage: CoachLanguage.english,
        ),
        <ChatMessage>[pendingPlaceholder],
      ).drain<void>();

      final rendered = utf8.decode(adapter.lastBody);
      expect(rendered, isNot(contains('a_pending')));
    });
  });

  group('script mismatch check', () {
    test('an English answer to a Japanese request is flagged', () {
      expect(looksLikeLanguageMismatch('It is raining today.', 'ja'), isTrue);
    });

    test('a Japanese answer is not flagged', () {
      expect(
        looksLikeLanguageMismatch('今日は雨が降っています。', 'ja'),
        isFalse,
      );
    });

    test('kanji-only Japanese is not flagged', () {
      expect(looksLikeLanguageMismatch('今日は雨', 'ja'), isFalse);
    });

    test('an empty answer is never flagged', () {
      expect(looksLikeLanguageMismatch('   ', 'ja'), isFalse);
    });

    test('a Chinese answer to an English request is flagged', () {
      expect(looksLikeLanguageMismatch('今天下雨。', 'en'), isTrue);
    });
  });

  group('explicit language resolution', () {
    final resolver = TargetLanguageResolver();

    test('returns null when the text names no language', () {
      expect(resolver.resolveExplicit('今天天气怎么样'), isNull);
    });

    test('detects a named language', () {
      expect(resolver.resolveExplicit('用日语怎么说'), CoachLanguage.japanese);
      expect(resolver.resolveExplicit('用英语怎么说'), CoachLanguage.english);
    });

    test('mixed CJK + English input resolves to the named language', () {
      expect(
        resolver.resolveExplicit('how do I say 谢谢 in Japanese please'),
        CoachLanguage.japanese,
      );
    });

    test('falls back to the conversation language when nothing is named', () {
      expect(
        resolver.resolve('今天天气怎么样', CoachLanguage.german),
        CoachLanguage.german,
      );
    });
  });
}
