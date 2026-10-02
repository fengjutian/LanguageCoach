import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/chat/application/waveform_controller.dart';

class _ScriptedBridge implements NativeAiBridge {
  final _events = StreamController<Object?>.broadcast();
  Stream<Object?> get _stream => _events.stream;

  void emitLevel(double db) {
    _events.add(<String, Object?>{
      'type': 'ASR_LEVEL',
      'payload': <String, Object?>{'level': db},
    });
  }

  void emitOther() {
    _events.add(<String, Object?>{
      'type': 'ASR_PARTIAL',
      'payload': <String, Object?>{'text': 'hi'},
    });
  }

  @override
  Stream<Object?> get eventStream => _stream;

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
  test('ASR_LEVEL frames populate the ring buffer; non-level frames ignored',
      () async {
    final bridge = _ScriptedBridge();
    final container = ProviderContainer(overrides: [
      nativeAiBridgeProvider.overrideWithValue(bridge),
    ]);
    addTearDown(container.dispose);

    final controller = container.read(waveformControllerProvider.notifier);
    expect(container.read(waveformControllerProvider).levels, isEmpty);
    // Touch `controller` so the unused-variable lint doesn't fire — the
    // provider initialises the bridge subscription as soon as we read it.
    expect(controller, isNotNull);

    bridge.emitLevel(-30); // floor
    bridge.emitOther();
    bridge.emitLevel(-2); // reference
    bridge.emitLevel(-16); // mid
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final levels = container.read(waveformControllerProvider).levels;
    expect(levels, hasLength(3));
    expect(levels.first, 0);
    expect(levels.last, closeTo(0.5, 0.05));
  });

  test('reset() clears the buffer', () async {
    final bridge = _ScriptedBridge();
    final container = ProviderContainer(overrides: [
      nativeAiBridgeProvider.overrideWithValue(bridge),
    ]);
    addTearDown(container.dispose);
    final controller = container.read(waveformControllerProvider.notifier);
    bridge.emitLevel(-10);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(waveformControllerProvider).levels, hasLength(1));
    controller.reset();
    expect(container.read(waveformControllerProvider).levels, isEmpty);
  });

  test('ring buffer caps at the configured capacity', () async {
    final bridge = _ScriptedBridge();
    final container = ProviderContainer(overrides: [
      nativeAiBridgeProvider.overrideWithValue(bridge),
    ]);
    addTearDown(container.dispose);
    for (var i = 0; i < 80; i++) {
      bridge.emitLevel(-10);
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final levels = container.read(waveformControllerProvider).levels;
    expect(levels.length, lessThanOrEqualTo(60));
  });
}