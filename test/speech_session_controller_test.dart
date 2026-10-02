import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/asr_model_profile.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/chat/application/speech_session_controller.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';

class _ScriptedBridge implements NativeAiBridge {
  _ScriptedBridge();
  final List<String> methodCalls = <String>[];
  final _eventController = StreamController<Object?>.broadcast();

  void emit(Object? event) => _eventController.add(event);

  @override
  Stream<Object?> get eventStream => _eventController.stream;

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
    return sessionId;
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
  Future<List<Map<Object?, Object?>>> listLlmModels() async {
    methodCalls.add('listLlmModels');
    return const [];
  }

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
  Future<List<Map<Object?, Object?>>> listAsrProfiles() async {
    methodCalls.add('listAsrProfiles');
    return knownAsrProfiles()
        .map((p) => <String, Object?>{
              'id': p.id,
              'languageCode': p.languageCode,
              'label': p.label,
              'sizeBytes': p.sizeBytes,
              'accuracyTier': p.accuracyTier.name,
              'transducer': p.transducer,
            })
        .toList();
  }

  @override
  Future<bool> loadAsrProfile({
    required String profileId,
    required String languageCode,
  }) async {
    methodCalls.add('loadAsrProfile:$profileId:$languageCode');
    return true;
  }

  @override
  Future<void> startAsrCapture({
    required String preferredAsrLanguage,
    String? profileId,
    int? silenceTimeoutMs,
  }) async {
    methodCalls.add('startAsrCapture:$preferredAsrLanguage');
  }

  @override
  Future<void> stopAsrCapture() async => methodCalls.add('stopAsrCapture');

  @override
  Future<void> cancelAsrCapture() async => methodCalls.add('cancelAsrCapture');

  @override
  Future<bool> isSpeechRecognitionAvailable() async => true;

  @override
  Future<void> startListening({required String language}) async =>
      methodCalls.add('startListening:$language');

  @override
  Future<void> stopListening() async => methodCalls.add('stopListening');

  @override
  Future<void> cancelListening() async => methodCalls.add('cancelListening');
}

class _SeededSettings extends SettingsController {
  @override
  AppSettings build() => AppSettings.defaults.copyWith(
        preferredLanguage: CoachLanguage.french,
      );
}

ProviderContainer _container(_ScriptedBridge bridge) {
  return ProviderContainer(overrides: [
    nativeAiBridgeProvider.overrideWithValue(bridge),
    settingsControllerProvider.overrideWith(() => _SeededSettings()),
  ]);
}

void main() {
  test('resolvedAsrLanguageProvider falls back to coach target', () {
    final container = _container(_ScriptedBridge());
    addTearDown(container.dispose);
    // Explicit ASR input language is null → use the coach preference.
    expect(container.read(resolvedAsrLanguageProvider), 'fr');
  });

  test('ensureEngineReady loads sherpa-onnx profile when chosen', () async {
    final bridge = _ScriptedBridge();
    final container = _container(bridge);
    addTearDown(container.dispose);
    container.read(asrEngineChoiceProvider.notifier).set(AsrEngineChoice.sherpaOnnx);
    final controller = container.read(speechSessionControllerProvider.notifier);
    final ready = await controller.ensureEngineReady();
    expect(ready, isTrue);
    expect(bridge.methodCalls, contains('listAsrProfiles'));
    expect(
      bridge.methodCalls.any((c) => c.startsWith('loadAsrProfile:')),
      isTrue,
    );
    final state = container.read(speechSessionControllerProvider);
    expect(state.engineReady, isTrue);
    expect(state.activeProfile, isNotNull);
  });

  test('start() routes through chosen engine', () async {
    final bridge = _ScriptedBridge();
    final container = _container(bridge);
    addTearDown(container.dispose);
    container.read(asrEngineChoiceProvider.notifier).set(AsrEngineChoice.sherpaOnnx);
    final controller = container.read(speechSessionControllerProvider.notifier);
    await controller.ensureEngineReady();
    await controller.start();
    expect(
      bridge.methodCalls.firstWhere(
        (c) => c.startsWith('startAsrCapture'),
        orElse: () => '',
      ),
      startsWith('startAsrCapture'),
    );
  });

  test('partial + final ASR events flow into the session state', () async {
    final bridge = _ScriptedBridge();
    final container = _container(bridge);
    addTearDown(container.dispose);

    final controller = container.read(speechSessionControllerProvider.notifier);
    await controller.ensureEngineReady();
    await controller.start();
    bridge.emit(<String, Object?>{
      'type': 'ASR_PARTIAL',
      'payload': {'text': 'hel'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(container.read(speechSessionControllerProvider).partialText, 'hel');
    bridge.emit(<String, Object?>{
      'type': 'ASR_FINAL',
      'payload': {'text': 'hello', 'language': 'en-US'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final state = container.read(speechSessionControllerProvider);
    expect(state.partialText, 'hello');
    expect(state.listening, isFalse);
  });
}
