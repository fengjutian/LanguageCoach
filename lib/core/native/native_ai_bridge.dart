import 'package:language_coach/core/audio/asr_engine.dart';
import 'package:language_coach/core/audio/asr_model_profile.dart';
import 'package:flutter/services.dart';

/// Stable Flutter boundary for the Kotlin Native AI Core.
/// Commands use MethodChannel; streaming ASR/LLM/TTS events use EventChannel.
///
/// The interface lives here so tests can drop in a [FakeNativeAiBridge]
/// without binding to the platform side; production code uses
/// [DefaultBridge] which delegates to [MethodChannel] / [EventChannel].
abstract interface class NativeAiBridge {
  Stream<Object?> get eventStream;

  // ---------- LLM (P0-2 retained for completeness) ----------
  Future<Map<Object?, Object?>?> generate({
    required String prompt,
    required String model,
  });

  // ---------- TTS (P1-3) ----------
  Future<String?> synthesize({
    required String text,
    required String language,
    String? voice,
    double? speed,
    String? model,
  });

  Future<String> loadModel({
    required String modelId,
    required String manifestJson,
    String? localDirectory,
  });

  Future<int> warmupModel({required String modelId});
  Future<void> unloadModel({required String modelId});
  Future<bool> cancelSynthesis();
  Future<Map<Object?, Object?>?> benchmarkSnapshot();

  // ---------- ASR (P1-4) ----------
  /// Returns every ASR profile the runtime knows about, regardless of
  /// install state. The Flutter side cross-references against
  /// [loadAsrProfile] to mark installed / not-installed in the UI.
  Future<List<Map<Object?, Object?>>> listAsrProfiles();

  /// Load [profileId] into the native ASR runtime. Returns `true` if the
  /// model is now resident, `false` if the artifacts are missing.
  Future<bool> loadAsrProfile({
    required String profileId,
    required String languageCode,
  });

  /// Start a capture session. The native side opens the microphone,
  /// down-samples to 16 kHz mono PCM, and pipes the frames through both
  /// the VAD and the ASR. Use [preferredAsrLanguage] to pick a profile
  /// when the user picks "auto" — it does NOT need to equal the coach
  /// target language.
  Future<void> startAsrCapture({
    required String preferredAsrLanguage,
    String? profileId,
    int? silenceTimeoutMs,
  });

  /// Stop the active capture session and emit a final ASR result if any
  /// audio is still buffered. Safe to call when no session is active.
  Future<void> stopAsrCapture();

  /// Cancel the active capture session without emitting a final result.
  Future<void> cancelAsrCapture();

  /// Reuse for the legacy `system SpeechRecognizer` fallback path so the
  /// Kotlin side can keep the old wiring until the user opts in to
  /// sherpa-onnx.
  Future<bool> isSpeechRecognitionAvailable();
  Future<void> startListening({required String language});
  Future<void> stopListening();
  Future<void> cancelListening();
}

/// Production bridge backed by the platform channels defined on the Android
/// side in `MainActivity.kt`. Replace in tests with any other
/// [NativeAiBridge] implementation.
class DefaultBridge implements NativeAiBridge {
  const DefaultBridge();

  static const MethodChannel _commands =
      MethodChannel('language_coach/ai_commands');
  static const EventChannel _events = EventChannel('language_coach/ai_events');

  @override
  Stream<Object?> get eventStream => _events.receiveBroadcastStream();

  @override
  Future<Map<Object?, Object?>?> generate({
    required String prompt,
    required String model,
  }) =>
      _commands.invokeMapMethod('generate', {'prompt': prompt, 'model': model});

  @override
  Future<String?> synthesize({
    required String text,
    required String language,
    String? voice = 'default',
    double? speed = 1,
    String? model,
  }) =>
      _commands.invokeMethod<String>('synthesize', {
        'text': text,
        'language': language,
        'voice': voice,
        'speed': speed,
        'model': model,
      });

  @override
  Future<String> loadModel({
    required String modelId,
    required String manifestJson,
    String? localDirectory,
  }) =>
      _commands.invokeMethod<String>('loadModel', {
        'modelId': modelId,
        'manifestJson': manifestJson,
        'localDirectory': localDirectory,
      }).then((value) => value ?? modelId);

  @override
  Future<int> warmupModel({required String modelId}) =>
      _commands.invokeMethod<int>('warmupModel', {'modelId': modelId}).then(
        (v) => v ?? 0,
      );

  @override
  Future<void> unloadModel({required String modelId}) =>
      _commands.invokeMethod<void>('unloadModel', {'modelId': modelId});

  @override
  Future<bool> cancelSynthesis() =>
      _commands.invokeMethod<bool>('cancelSynthesis').then((v) => v ?? false);

  @override
  Future<Map<Object?, Object?>?> benchmarkSnapshot() =>
      _commands.invokeMapMethod('benchmarkSnapshot', null);

  @override
  Future<List<Map<Object?, Object?>>> listAsrProfiles() async {
    final raw = await _commands.invokeMethod<List<Object?>>('listAsrProfiles');
    return raw?.cast<Map<Object?, Object?>>() ?? const [];
  }

  @override
  Future<bool> loadAsrProfile({
    required String profileId,
    required String languageCode,
  }) =>
      _commands.invokeMethod<bool>('loadAsrProfile', {
        'profileId': profileId,
        'languageCode': languageCode,
      }).then((v) => v ?? false);

  @override
  Future<void> startAsrCapture({
    required String preferredAsrLanguage,
    String? profileId,
    int? silenceTimeoutMs,
  }) =>
      _commands.invokeMethod<void>('startAsrCapture', {
        'preferredAsrLanguage': preferredAsrLanguage,
        'profileId': profileId,
        'silenceTimeoutMs': silenceTimeoutMs,
      });

  @override
  Future<void> stopAsrCapture() =>
      _commands.invokeMethod<void>('stopAsrCapture');

  @override
  Future<void> cancelAsrCapture() =>
      _commands.invokeMethod<void>('cancelAsrCapture');

  @override
  Future<bool> isSpeechRecognitionAvailable() async =>
      await _commands.invokeMethod<bool>('isSpeechRecognitionAvailable') ??
      false;

  @override
  Future<void> startListening({required String language}) =>
      _commands.invokeMethod<void>('startListening', {'language': language});

  @override
  Future<void> stopListening() => _commands.invokeMethod<void>('stopListening');

  @override
  Future<void> cancelListening() =>
      _commands.invokeMethod<void>('cancelListening');
}

/// Helper to bridge the Kotlin event payloads into typed Dart objects.
extension NativeAsrEventDecoder on Object? {
  /// Pull an [AsrResult] out of an event-channel payload shaped like
  /// `{'type': 'ASR_*', 'payload': {...}}`.
  AsrResult? toAsrResult() {
    if (this is! Map) return null;
    final map = this as Map;
    if (map['type'] is! String) return null;
    final type = map['type'] as String;
    final payload = map['payload'];
    if (payload is! Map) return null;
    final data = payload;
    switch (type) {
      case 'ASR_PARTIAL':
        return AsrPartial((data['text'] as String?) ?? '');
      case 'ASR_FINAL':
        return AsrFinal(
          (data['text'] as String?) ?? '',
          (data['language'] as String?) ?? 'auto',
        );
      case 'ASR_ERROR':
        final message = (data['message'] as String?) ?? '语音识别失败';
        final code = (data['code'] as int?) ?? 0;
        final kind = _mapAsrError(code);
        return AsrFailure(kind, message);
    }
    return null;
  }
}

AsrErrorKind _mapAsrError(int code) {
  // Mirrors `SpeechRecognizer.ERROR_*` constants — the sherpa-onnx runtime
  // uses the same numbering so existing UI strings stay accurate.
  switch (code) {
    case 1:
      return AsrErrorKind.timeout;
    case 2:
      return AsrErrorKind.format;
    case 4:
      return AsrErrorKind.permissionDenied;
    case 5:
      return AsrErrorKind.permissionDenied;
    case 6:
      return AsrErrorKind.timeout;
    case 7:
      return AsrErrorKind.busy;
    case 8:
      return AsrErrorKind.busy;
    case 9:
      return AsrErrorKind.unavailable;
    default:
      return AsrErrorKind.unknown;
  }
}

/// Decode the JSON metadata the Kotlin side returns from `listAsrProfiles`
/// into typed [AsrModelProfile]s.
List<AsrModelProfile> decodeAsrProfiles(List<Map<Object?, Object?>> raw) {
  return raw.map((m) {
    return AsrModelProfile(
      id: (m['id'] as String?) ?? '',
      languageCode: (m['languageCode'] as String?) ?? 'auto',
      label: (m['label'] as String?) ?? '',
      sizeBytes: (m['sizeBytes'] as int?) ?? 0,
      accuracyTier: _tierFromString(m['accuracyTier'] as String?),
      transducer: (m['transducer'] as String?) ?? 'whisper',
    );
  }).toList();
}

AccuracyTier _tierFromString(String? raw) {
  switch (raw) {
    case 'large':
      return AccuracyTier.large;
    case 'medium':
      return AccuracyTier.medium;
    default:
      return AccuracyTier.small;
  }
}
