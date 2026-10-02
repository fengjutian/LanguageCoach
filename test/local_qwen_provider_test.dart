import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/local_qwen_provider.dart';
import 'package:language_coach/core/audio/model_manifest.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';

/// Stand-in bridge that records lifecycle calls and lets the test script
/// events back through `eventStream` synchronously.
class _ScriptedBridge implements NativeAiBridge {
  final List<String> methodCalls = <String>[];
  final _events = StreamController<Object?>.broadcast();

  bool startRejects = false;

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
      final sessionId =
          bridge.methodCalls.last.split(':')[1].split(':')[0];

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
      await provider
          .generateStream(
            const CoachRequest(
              text: 'hello',
              targetLanguage: CoachLanguage.english,
              intent: CoachIntent.conversation,
            ),
            const <ChatMessage>[],
          )
          .forEach(received.add);
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
      final sessionId =
          bridge.methodCalls.last.split(':')[1].split(':')[0];

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
      final sessionId =
          bridge.methodCalls.last.split(':')[1].split(':')[0];

      await sub.cancel();
      await pumpMicrotasks();

      expect(bridge.methodCalls, contains('cancelLlmGeneration:$sessionId'));
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