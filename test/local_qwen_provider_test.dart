import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/local_qwen_provider.dart';
import 'package:language_coach/core/audio/model_manifest.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';
import 'package:language_coach/core/network/api_client.dart';

/// Stand-in bridge that records lifecycle calls and lets the test script
/// events back through `eventStream` synchronously.
class _ScriptedBridge implements NativeAiBridge {
  final List<String> methodCalls = <String>[];
  final _events = StreamController<Object?>.broadcast();

  /// Prompt handed to the last `startLlmGeneration` call.
  String? lastPrompt;
  bool startRejects = false;

  /// Simulates an Android EventChannel teardown: the stream completes
  /// without ever delivering LLM_COMPLETE / LLM_ERROR.
  Future<void> closeEventStream() => _events.close();

  void emitLlmToken(String sessionId, String token, [int? index]) {
    _events.add(<String, Object?>{
      'type': 'LLM_TOKEN',
      'sessionId': sessionId,
      'payload': <String, Object?>{
        'token': token,
        if (index != null) 'index': index,
      },
    });
  }

  void emitLlmComplete(String sessionId) {
    _events.add(<String, Object?>{
      'type': 'LLM_COMPLETE',
      'sessionId': sessionId,
      'payload': <String, Object?>{'tokensEmitted': 0},
    });
  }

  void emitLlmError(String sessionId, String message) {
    _events.add(<String, Object?>{
      'type': 'LLM_ERROR',
      'sessionId': sessionId,
      'payload': <String, Object?>{'message': message},
    });
  }

  @override
  Stream<Object?> get eventStream => _events.stream;

  @override
  Future<String?> loadLlmModel({
    required String modelId,
    String? manifestJson,
    String? localDirectory,
  }) async {
    methodCalls.add('loadLlmModel:$modelId');
    return modelId;
  }

  @override
  Future<String?> startLlmGeneration({
    required String sessionId,
    required String prompt,
    required String modelId,
    int? maxTokens,
    double? temperature,
  }) async {
    methodCalls.add('startLlmGeneration:$sessionId:$modelId');
    lastPrompt = prompt;
    return startRejects ? null : sessionId;
  }

  @override
  Future<void> cancelLlmGeneration({required String sessionId}) async {
    methodCalls.add('cancelLlmGeneration:$sessionId');
  }

  @override
  Future<void> unloadLlmModel({required String modelId}) async {
    methodCalls.add('unloadLlmModel:$modelId');
  }

  @override
  Future<List<Map<Object?, Object?>>> listLlmModels() async => const [];

  // -------- surface retained for ASR/TTS paths (untouched here) --------
  @override
  Future<String?> synthesize({
    required String text,
    required String language,
    String? voice,
    double? speed,
    String? model,
  }) async =>
      null;

  @override
  Future<String> loadModel({
    required String modelId,
    required String manifestJson,
    String? localDirectory,
  }) async =>
      modelId;

  @override
  Future<int> warmupModel({required String modelId}) async => 0;

  @override
  Future<void> unloadModel({required String modelId}) async {}

  @override
  Future<bool> cancelSynthesis() async => false;

  @override
  Future<Map<Object?, Object?>?> benchmarkSnapshot() async => null;

  @override
  Future<List<Map<Object?, Object?>>> listAsrProfiles() async => const [];

  @override
  Future<bool> loadAsrProfile({
    required String profileId,
    required String languageCode,
  }) async =>
      false;

  @override
  Future<void> startAsrCapture({
    required String preferredAsrLanguage,
    String? profileId,
    int? silenceTimeoutMs,
  }) async {}

  @override
  Future<void> stopAsrCapture() async {}

  @override
  Future<void> cancelAsrCapture() async {}

  @override
  Future<bool> isSpeechRecognitionAvailable() async => false;

  @override
  Future<void> startListening({required String language}) async {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> cancelListening() async {}
}

void main() {
  group('LocalQwenProvider', () {
    test('prior user turns reach the prompt', () async {
      final bridge = _ScriptedBridge();
      final provider =
          LocalQwenProvider(bridge: bridge, modelId: qwen3Llm06B.id);

      // User turns carry their text in `sourceText` with a null `response`.
      // Reading only `response` emitted an empty `user:` line for every one
      // of them, so the model never saw what the user actually said.
      final context = <ChatMessage>[
        ChatMessage(
          id: 'u1',
          role: MessageRole.user,
          sourceText: 'Where is the station?',
          createdAt: DateTime(2026, 1, 1),
        ),
        ChatMessage(
          id: 'a1',
          role: MessageRole.assistant,
          createdAt: DateTime(2026, 1, 1),
          response: CoachResponse(
            intent: CoachIntent.conversation,
            sourceLanguage: 'auto',
            targetLanguage: 'en',
            primary: 'It is two blocks away.',
            explanation: '',
            sentences: const <CoachSentence>[],
          ),
        ),
      ];

      final sub = provider
          .generateStream(
            CoachRequest(
              text: 'thanks',
              targetLanguage: CoachLanguage.english,
              intent: CoachIntent.conversation,
            ),
            context,
          )
          .listen((_) {});
      addTearDown(() => _ignoreFuture(sub.cancel()));
      await pumpMicrotasks();

      final prompt = bridge.lastPrompt ?? '';
      expect(prompt, contains('user: Where is the station?'));
      expect(prompt, contains('assistant: It is two blocks away.'));
      expect(prompt, contains('<EXPLANATION>'));
      expect(prompt, contains('<CHINESE_TRANSLATION>'));
      expect(prompt, contains('Never leave any section empty'));
    });

    test('separates the local teaching explanation from the answer', () async {
      final bridge = _ScriptedBridge();
      final provider =
          LocalQwenProvider(bridge: bridge, modelId: qwen3Llm06B.id);
      final received = <LlmEvent>[];
      final sub = provider.generateStream(
        const CoachRequest(
          text: '南京',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      ).listen(received.add);
      addTearDown(() => _ignoreFuture(sub.cancel()));
      await pumpMicrotasks();

      final sessionId = bridge.methodCalls.last.split(':')[1];
      bridge.emitLlmToken(
        sessionId,
        '<ANSWER>Nanjing<CHINESE_TRANSLATION>南京'
        '<EXPLANATION>“南京”译作 Nanjing，读音按汉语拼音转写。',
      );
      bridge.emitLlmComplete(sessionId);
      await pumpMicrotasks();

      final response = received.whereType<LlmEventComplete>().single.response;
      expect(response.primary, 'Nanjing');
      expect(response.chineseTranslation, '南京');
      expect(response.explanation, contains('汉语拼音'));
      expect(response.primary, isNot(contains('<ANSWER>')));
    });

    test('stream ending without LLM_COMPLETE still settles', () async {
      final bridge = _ScriptedBridge();
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
      );

      final stream = provider.generateStream(
        CoachRequest(
          text: 'hello',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      );
      final received = <LlmEvent>[];
      final done = Completer<void>();
      final sub = stream.listen(received.add, onDone: done.complete);
      addTearDown(() => _ignoreFuture(sub.cancel()));

      await pumpMicrotasks();
      final sessionId = bridge.methodCalls.last.split(':')[1];
      bridge.emitLlmToken(sessionId, 'Partial answer');

      // The bridge is a broadcast EventChannel: on Android teardown (activity
      // destroy, model unload) it simply completes. Without an `onDone` the
      // controller was never closed, so the chat bubble spun forever with a
      // dead stop button.
      await bridge.closeEventStream();

      await done.future.timeout(const Duration(seconds: 2));
      expect(received.whereType<LlmEventComplete>(), hasLength(1));
      expect(
        received.whereType<LlmEventComplete>().single.response.primary,
        contains('Partial answer'),
      );
    });

    test('an idle stream times out instead of hanging forever', () async {
      final bridge = _ScriptedBridge();
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
        idleTimeout: const Duration(milliseconds: 120),
      );

      final received = <LlmEvent>[];
      final done = Completer<void>();
      final sub = provider.generateStream(
        CoachRequest(
          text: 'hello',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      ).listen(received.add, onDone: done.complete);
      addTearDown(() => _ignoreFuture(sub.cancel()));

      await done.future.timeout(const Duration(seconds: 5));
      final errors = received.whereType<LlmEventError>();
      expect(errors, hasLength(1));
      expect(errors.single.error.kind, LlmErrorKind.timeout);
    });

    test('emits delta events while the bridge streams tokens, then a complete',
        () async {
      final bridge = _ScriptedBridge();
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
      );

      final request = CoachRequest(
        text: 'hello',
        targetLanguage: CoachLanguage.english,
        intent: CoachIntent.conversation,
      );
      final stream = provider.generateStream(request, const <ChatMessage>[]);
      final received = <LlmEvent>[];
      final sub = stream.listen(received.add);
      addTearDown(() => _ignoreFuture(sub.cancel()));

      // Let the provider's run() finish setting up the session.
      await pumpMicrotasks();
      expect(bridge.methodCalls.last, startsWith('startLlmGeneration:'));
      final sessionId = bridge.methodCalls.last.split(':')[1].split(':')[0];

      bridge.emitLlmToken(sessionId, 'Hel', 0);
      bridge.emitLlmToken(sessionId, 'lo', 1);
      bridge.emitLlmComplete(sessionId);
      await pumpMicrotasks();

      expect(
        received.whereType<LlmEventDelta>().map((e) => e.text).toList(),
        ['Hel', 'lo'],
      );
      final complete = received.whereType<LlmEventComplete>().single;
      expect(complete.response.primary, 'Hello');
      expect(complete.response.targetLanguage, 'en');
      expect(complete.assistantMessage.model, provider.id);
      expect(
        bridge.methodCalls,
        isNot(contains('cancelLlmGeneration:$sessionId')),
      );
    });

    test('when bridge rejects the start, emits a LLM_ERROR', () async {
      final bridge = _ScriptedBridge()..startRejects = true;
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
      );
      final received = <LlmEvent>[];
      await provider.generateStream(
        const CoachRequest(
          text: 'hello',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      ).forEach(received.add);
      expect(received, hasLength(1));
      final err = received.single as LlmEventError;
      expect(err.error.message, contains('未加载'));
    });

    test('LLM_ERROR mid-stream surfaces as LlmEventError', () async {
      final bridge = _ScriptedBridge();
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
      );
      final received = <LlmEvent>[];
      final stream = provider.generateStream(
        const CoachRequest(
          text: 'hi',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      );
      final sub = stream.listen(received.add);
      addTearDown(() => _ignoreFuture(sub.cancel()));

      await pumpMicrotasks();
      final sessionId = bridge.methodCalls.last.split(':')[1].split(':')[0];

      bridge.emitLlmToken(sessionId, 'Hel', 0);
      bridge.emitLlmError(sessionId, 'native failure');
      await pumpMicrotasks();

      expect(received.whereType<LlmEventDelta>(), hasLength(1));
      final err = received.whereType<LlmEventError>().single;
      expect(err.error.message, 'native failure');
    });

    test('cancelling the consumer subscription cancels the runtime session',
        () async {
      final bridge = _ScriptedBridge();
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
      );
      final stream = provider.generateStream(
        const CoachRequest(
          text: 'ping',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      );
      final sub = stream.listen((_) {});
      await pumpMicrotasks();
      final sessionId = bridge.methodCalls.last.split(':')[1].split(':')[0];

      await sub.cancel();
      await pumpMicrotasks();

      expect(bridge.methodCalls, contains('cancelLlmGeneration:$sessionId'));
    });

    test(
        'multi-sentence text gets split + keyword extractor surfaces '
        'recurring vocabulary', () async {
      final bridge = _ScriptedBridge();
      final provider = LocalQwenProvider(
        bridge: bridge,
        modelId: qwen3Llm06B.id,
      );

      final stream = provider.generateStream(
        const CoachRequest(
          text: 'teach me about coffee shops in Paris',
          targetLanguage: CoachLanguage.english,
          intent: CoachIntent.conversation,
        ),
        const <ChatMessage>[],
      );
      final received = <LlmEvent>[];
      final sub = stream.listen(received.add);
      addTearDown(() => _ignoreFuture(sub.cancel()));

      await pumpMicrotasks();
      final sessionId = bridge.methodCalls.last.split(':')[1].split(':')[0];

      bridge.emitLlmToken(sessionId, 'Coffee shops ', 0);
      bridge.emitLlmToken(sessionId, 'in Paris ', 1);
      bridge.emitLlmToken(sessionId, 'are wonderful. ', 2);
      bridge.emitLlmToken(sessionId, 'You can order ', 3);
      bridge.emitLlmToken(sessionId, 'a coffee ', 4);
      bridge.emitLlmToken(sessionId, 'and enjoy the view.', 5);
      bridge.emitLlmComplete(sessionId);
      await pumpMicrotasks();

      final complete = received.whereType<LlmEventComplete>().single;
      // SentenceSplitter splits on `. ` so we expect two sentences.
      expect(complete.response.sentences, hasLength(2));
      expect(complete.response.sentences[0].id, 's1');
      expect(complete.response.sentences[0].text, contains('wonderful'));
      expect(complete.response.sentences[1].id, 's2');
      // 'coffee' appears twice and isn't a stopword — must surface.
      expect(complete.response.keywords, contains('coffee'));
    });
  });
}

/// Lets the StreamController's `run()` Future progress and any microtask-
/// scheduled events flush without depending on real wall time.
Future<void> pumpMicrotasks() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void _ignoreFuture(Future<void> _) {}
