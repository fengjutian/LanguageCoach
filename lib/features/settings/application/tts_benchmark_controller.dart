import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/model_manifest.dart';
import '../../../core/audio/native_qwen_tts_engine.dart';
import '../../../core/audio/tts_engine.dart';
import '../../../core/native/native_ai_bridge.dart';
import '../../chat/application/conversation_providers.dart';

/// One benchmark record. Captured in the order the test ran; the UI keeps
/// the most recent first.
class BenchmarkRecord {
  BenchmarkRecord({
    required this.label,
    required this.startedAt,
    required this.durationMs,
    this.peakRssKb,
    this.currentRssKb,
    this.threadCount,
    this.modelId,
    this.error,
  });

  final String label;
  final DateTime startedAt;
  final int durationMs;
  final int? peakRssKb;
  final int? currentRssKb;
  final int? threadCount;
  final String? modelId;
  final String? error;

  bool get hasError => error != null;
}

/// Snapshot pulled from [NativeAiBridge.benchmarkSnapshot] + a timestamp.
class BenchmarkSnapshot {
  BenchmarkSnapshot({
    required this.capturedAt,
    required this.values,
  });
  final DateTime capturedAt;
  final Map<Object?, Object?> values;
}

/// One model that the benchmark page knows about. Drives the dropdown and
/// also the manifest serialised into the native `loadModel` call.
class BenchmarkModel {
  const BenchmarkModel({required this.id, required this.manifest});
  final String id;
  final ModelManifest manifest;
}

const _kBenchmarkModels = <BenchmarkModel>[
  BenchmarkModel(id: 'qwen3-tts-0.6B', manifest: qwen3Tts06B),
];

/// State object driving the benchmark UI. The page watches this and
/// renders snapshots + records in the order they were captured.
class BenchmarkState {
  BenchmarkState({
    required this.modelId,
    required this.loaded,
    required this.snapshot,
    required this.records,
    required this.busy,
  });
  final String modelId;
  final bool loaded;
  final BenchmarkSnapshot? snapshot;
  final List<BenchmarkRecord> records;
  final bool busy;

  BenchmarkState copyWith({
    String? modelId,
    bool? loaded,
    BenchmarkSnapshot? snapshot,
    bool clearSnapshot = false,
    List<BenchmarkRecord>? records,
    bool? busy,
  }) {
    return BenchmarkState(
      modelId: modelId ?? this.modelId,
      loaded: loaded ?? this.loaded,
      snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
      records: records ?? this.records,
      busy: busy ?? this.busy,
    );
  }
}

final ttsBenchmarkControllerProvider =
    NotifierProvider<TtsBenchmarkController, BenchmarkState>(
  TtsBenchmarkController.new,
);

class TtsBenchmarkController extends Notifier<BenchmarkState> {
  NativeAiBridge get _bridge => ref.read(nativeAiBridgeProvider);

  @override
  BenchmarkState build() {
    return BenchmarkState(
      modelId: _kBenchmarkModels.first.id,
      loaded: false,
      snapshot: null,
      records: const <BenchmarkRecord>[],
      busy: false,
    );
  }

  Future<void> loadSelected() async {
    final manifest = _manifestFor(state.modelId);
    if (manifest == null) return;
    state = state.copyWith(busy: true);
    final stopwatch = Stopwatch()..start();
    try {
      final echoed = await _bridge.loadModel(
        modelId: manifest.id,
        manifestJson: _manifestJson(manifest),
      );
      stopwatch.stop();
      state = state.copyWith(
        loaded: true,
        busy: false,
        records: [
          BenchmarkRecord(
            label: 'load ${manifest.id}',
            startedAt: DateTime.now(),
            durationMs: stopwatch.elapsedMilliseconds,
            modelId: echoed,
          ),
          ...state.records,
        ],
      );
      await _refreshSnapshot();
    } catch (e) {
      stopwatch.stop();
      state = state.copyWith(
        busy: false,
        records: [
          BenchmarkRecord(
            label: 'load ${manifest.id}',
            startedAt: DateTime.now(),
            durationMs: stopwatch.elapsedMilliseconds,
            error: e.toString(),
          ),
          ...state.records,
        ],
      );
    }
  }

  Future<void> warmup() async {
    final manifest = _manifestFor(state.modelId);
    if (manifest == null) return;
    state = state.copyWith(busy: true);
    final stopwatch = Stopwatch()..start();
    try {
      await _bridge.warmupModel(modelId: manifest.id);
      stopwatch.stop();
      state = state.copyWith(
        busy: false,
        records: [
          BenchmarkRecord(
            label: 'warmup ${manifest.id}',
            startedAt: DateTime.now(),
            durationMs: stopwatch.elapsedMilliseconds,
          ),
          ...state.records,
        ],
      );
    } catch (e) {
      stopwatch.stop();
      state = state.copyWith(
        busy: false,
        records: [
          BenchmarkRecord(
            label: 'warmup ${manifest.id}',
            startedAt: DateTime.now(),
            durationMs: stopwatch.elapsedMilliseconds,
            error: e.toString(),
          ),
          ...state.records,
        ],
      );
    }
  }

  Future<void> synthesize(String text) async {
    if (text.trim().isEmpty) return;
    final manifest = _manifestFor(state.modelId);
    if (manifest == null) return;
    state = state.copyWith(busy: true);
    final stopwatch = Stopwatch()..start();
    String? audioPath;
    String? errorMessage;
    try {
      audioPath = await _bridge.synthesize(
        text: text,
        language: 'en',
        voice: 'default',
        speed: 1.0,
        model: manifest.id,
      );
    } catch (e) {
      errorMessage = e.toString();
    }
    stopwatch.stop();
    state = state.copyWith(
      busy: false,
      records: [
        BenchmarkRecord(
          label: 'synthesize (${text.length} chars)',
          startedAt: DateTime.now(),
          durationMs: stopwatch.elapsedMilliseconds,
          error: errorMessage,
        ),
        ...state.records,
      ],
    );
    await _refreshSnapshot();
    // Suppress unused — the path is left for the caller to inspect via
    // the debug panel; native side has already written the wav.
    // ignore: unused_local_variable
    audioPath;
  }

  Future<void> cancel() async {
    state = state.copyWith(busy: true);
    try {
      await _bridge.cancelSynthesis();
    } finally {
      state = state.copyWith(busy: false);
    }
  }

  Future<void> unload() async {
    final manifest = _manifestFor(state.modelId);
    if (manifest == null) return;
    state = state.copyWith(busy: true);
    try {
      await _bridge.unloadModel(modelId: manifest.id);
      state = state.copyWith(loaded: false, snapshot: null, busy: false);
    } catch (_) {
      state = state.copyWith(busy: false);
    }
  }

  void selectModel(String id) {
    state = state.copyWith(
      modelId: id,
      loaded: false,
      clearSnapshot: true,
      records: const <BenchmarkRecord>[],
    );
  }

  Future<void> _refreshSnapshot() async {
    try {
      final raw = await _bridge.benchmarkSnapshot();
      if (raw == null) return;
      state = state.copyWith(
        snapshot: BenchmarkSnapshot(capturedAt: DateTime.now(), values: raw),
      );
    } catch (_) {
      // best-effort
    }
  }

  ModelManifest? _manifestFor(String id) {
    for (final m in _kBenchmarkModels) {
      if (m.id == id) return m.manifest;
    }
    return null;
  }

  String _manifestJson(ModelManifest m) {
    return 'placeholder manifest (id=${m.id} version=${m.version})';
  }
}

/// Helper kept on the engine side so the benchmark page can stub a fake
/// [NativeQwenTtsEngine] for offline widget tests.
TtsEngine buildStubEngine({String id = 'qwen3-tts'}) => NativeQwenTtsEngine(
      bridge: _StubBridge(),
      modelId: id,
    );

class _StubBridge implements NativeAiBridge {
  @override
  Stream<Object?> get eventStream => const Stream.empty();
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
  Future<String> loadModel(
          {required String modelId,
          required String manifestJson,
          String? localDirectory}) async =>
      modelId;
  @override
  Future<int> warmupModel({required String modelId}) async => 0;
  @override
  Future<void> unloadModel({required String modelId}) async {}
  @override
  Future<bool> cancelSynthesis() async => false;
  @override
  Future<Map<Object?, Object?>?> benchmarkSnapshot() async => <String, Object?>{
        'isLoaded': true,
        'currentRssKb': 1234,
        'peakRssKb': 5678,
        'threadCount': 12,
      };
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
