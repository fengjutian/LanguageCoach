import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/model_manifest.dart';
import 'package:language_coach/core/audio/native_qwen_tts_engine.dart';
import 'package:language_coach/core/audio/tts_models.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/settings/application/tts_benchmark_controller.dart';

/// In-memory fake of the native bridge that records lifecycle calls and
/// simulates a successful synthesize round-trip without touching the JNI.
class _FakeBridge implements NativeAiBridge {
  int loadCallCount = 0;
  final warmupMs = 12;
  final synthesizeMs = 240;
  String? loadedId;
  bool unloaded = false;
  bool cancelRequested = false;
  Directory? wavDirectory;

  @override
  Stream<Object?> get eventStream => const Stream.empty();

  @override
  Future<String?> synthesize({
    required String text,
    required String language,
    String? voice,
    double? speed,
    String? model,
  }) async {
    cancelRequested = false;
    await Future<void>.delayed(Duration(milliseconds: synthesizeMs ~/ 5));
    final dir =
        wavDirectory ?? Directory.systemTemp.createTempSync('fake_tts_');
    final path = '${dir.path}/synth_${text.hashCode}.wav';
    File(path).writeAsBytesSync(List<int>.filled(16, 0));
    return path;
  }

  @override
  Future<String> loadModel({
    required String modelId,
    required String manifestJson,
    String? localDirectory,
  }) async {
    loadCallCount++;
    loadedId = modelId;
    return modelId;
  }

  @override
  Future<int> warmupModel({required String modelId}) async {
    return warmupMs;
  }

  @override
  Future<void> unloadModel({required String modelId}) async {
    unloaded = true;
    loadedId = null;
  }

  @override
  Future<bool> cancelSynthesis() async {
    cancelRequested = true;
    return true;
  }

  @override
  Future<Map<Object?, Object?>?> benchmarkSnapshot() async => <String, Object?>{
        'isLoaded': loadedId != null,
        'currentRssKb': 4321,
        'peakRssKb': 9000,
        'threadCount': 8,
      };

  @override
  Future<List<Map<Object?, Object?>>> listAsrProfiles() async => const [];
  @override
  Future<bool> loadAsrProfile(
          {required String profileId, required String languageCode}) async =>
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

  @override
  Future<String?> loadLlmModel({
    required String modelId,
    String? manifestJson,
    String? localDirectory,
  }) async =>
      null;

  @override
  Future<String?> startLlmGeneration({
    required String sessionId,
    required String prompt,
    required String modelId,
    int? maxTokens,
    double? temperature,
  }) async =>
      null;

  @override
  Future<void> cancelLlmGeneration({required String sessionId}) async {}

  @override
  Future<void> unloadLlmModel({required String modelId}) async {}

  @override
  Future<List<Map<Object?, Object?>>> listLlmModels() async => const [];
}

ProviderContainer _container(_FakeBridge bridge) {
  return ProviderContainer(overrides: [
    nativeAiBridgeProvider.overrideWithValue(bridge),
  ]);
}

void main() {
  test('model_manifest exposes Qwen3-TTS 0.6B artifact layout', () {
    expect(qwen3Tts06B.id, 'qwen3-tts-0.6B');
    expect(qwen3Tts06B.type, 'tts');
    expect(qwen3Tts06B.supportedAbis, ['arm64-v8a']);
    final roles = qwen3Tts06B.artifacts.map((a) => a.role).toSet();
    expect(
        roles,
        containsAll(<String>[
          'tokenizer',
          'talker_weights',
          'decoder_config',
          'voice_profile',
        ]));
  });

  test('loadSelected calls the bridge and records duration', () async {
    final bridge = _FakeBridge();
    final container = _container(bridge);
    addTearDown(container.dispose);

    final controller = container.read(ttsBenchmarkControllerProvider.notifier);
    await controller.loadSelected();

    expect(bridge.loadCallCount, 1);
    expect(bridge.loadedId, 'qwen3-tts-0.6B');
    final state = container.read(ttsBenchmarkControllerProvider);
    expect(state.loaded, isTrue);
    expect(state.records, hasLength(1));
    expect(state.records.first.label, startsWith('load '));
    expect(state.snapshot, isNotNull);
  });

  test('synthesize records latency and updates snapshot', () async {
    final bridge = _FakeBridge();
    final container = _container(bridge);
    addTearDown(container.dispose);

    final controller = container.read(ttsBenchmarkControllerProvider.notifier);
    await controller.loadSelected();
    await controller.synthesize('hello world');
    final state = container.read(ttsBenchmarkControllerProvider);
    final synth = state.records.firstWhere(
      (r) => r.label.startsWith('synthesize'),
    );
    expect(synth.hasError, isFalse);
    expect(synth.durationMs, greaterThan(0));
  });

  test('unload clears loaded state', () async {
    final bridge = _FakeBridge();
    final container = _container(bridge);
    addTearDown(container.dispose);

    final controller = container.read(ttsBenchmarkControllerProvider.notifier);
    await controller.loadSelected();
    await controller.unload();
    final state = container.read(ttsBenchmarkControllerProvider);
    expect(state.loaded, isFalse);
    expect(bridge.unloaded, isTrue);
  });

  test('NativeQwenTtsEngine delegates to the bridge', () async {
    final bridge = _FakeBridge();
    final engine =
        NativeQwenTtsEngine(bridge: bridge, modelId: 'qwen3-tts-0.6B');
    final result = await engine.synthesize(const TtsRequest(
      text: 'hi',
      language: 'en',
    ));
    expect(result.audioPath, contains('synth_'));
    expect(result.format, 'wav');
    await engine.dispose();
  });
}


