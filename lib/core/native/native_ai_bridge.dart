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

  // ---------- LLM (P1-6 native) ----------
  /// Load [modelId] into the native LLM runtime. Returns the echoed
  /// `modelId` once the runtime is resident; `null` if the model files
  /// are missing on disk.
  Future<String?> loadLlmModel({
    required String modelId,
    String? manifestJson,
    String? localDirectory,
  });

  /// Start a streaming generation. Returns a `sessionId` the caller can
  /// pass back to [cancelLlmGeneration] and use to filter tokens out of
  /// [eventStream]. Returns `null` if the runtime rejected the request
  /// (no model loaded, model not ready, etc).
  Future<String?> startLlmGeneration({
    required String sessionId,
    required String prompt,
    required String modelId,
    int? maxTokens,
    double? temperature,
  });

  /// Cancel an in-flight generation. No-op if [sessionId] is unknown.
  Future<void> cancelLlmGeneration({required String sessionId});

  /// Releases the runtime binding for [modelId]. Disk artifacts stay.
  Future<void> unloadLlmModel({required String modelId});

  /// Snapshot of every LLM the runtime knows about, regardless of
  /// whether the artifacts are installed. Mirrors `listAsrProfiles`.
  Future<List<Map<Object?, Object?>>> listLlmModels();

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

  // `_events.receiveBroadcastStream()` returns a fresh broadcast stream on
  // every call AND triggers Kotlin `onListen`. Without this cache the
  // Flutter side stacks up redundant subscriptions, the Kotlin side
  // overwrites its `eventSink` on each call, and only the last
  // subscriber actually receives events. Cache one stream per bridge.
  late final Stream<Object?> _eventStream = _events.receiveBroadcastStream();

  @override
  Stream<Object?> get eventStream => _eventStream;

  @override
  Future<String?> loadLlmModel({
    required String modelId,
    String? manifestJson,
    String? localDirectory,
  }) =>
      _commands.invokeMethod<String>('loadLlmModel', {
        'modelId': modelId,
        'manifestJson': manifestJson,
        'localDirectory': localDirectory,
      });

  @override
  Future<String?> startLlmGeneration({
    required String sessionId,
    required String prompt,
    required String modelId,
    int? maxTokens,
    double? temperature,
  }) =>
      _commands.invokeMethod<String>('startLlmGeneration', {
        'sessionId': sessionId,
        'prompt': prompt,
        'modelId': modelId,
        'maxTokens': maxTokens,
        'temperature': temperature,
      });

  @override
  Future<void> cancelLlmGeneration({required String sessionId}) =>
      _commands.invokeMethod<void>('cancelLlmGeneration', {
        'sessionId': sessionId,
      });

  @override
  Future<void> unloadLlmModel({required String modelId}) =>
      _commands.invokeMethod<void>('unloadLlmModel', {'modelId': modelId});

  @override
  Future<List<Map<Object?, Object?>>> listLlmModels() async {
    final raw =
        await _commands.invokeMethod<List<Object?>>('listLlmModels');
    return raw?.cast<Map<Object?, Object?>>() ?? const [];
  }

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
  // Two sender conventions share this channel:
  //   - Android `SpeechRecognizer.ERROR_*` (1–9). The real values are:
  //       1=NETWORK_TIMEOUT, 2=NETWORK, 3=AUDIO,
  //       5=INSUFFICIENT_PERMISSIONS, 6=SERVER,
  //       7=RECOGNIZER_BUSY, 8=NO_MATCH, 9=SPEECH_TIMEOUT.
  //   - `AsrService` native-runtime convention (P1-4 stub):
  //       4=microphone permission denied,
  //       9=no model loaded (will switch to 1001/1002 once P1-5 ships).
  switch (code) {
    // Permission family.
    case 4: // AsrService: permission denied.
    case 5: // SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS.
    case 1001:
      return AsrErrorKind.permissionDenied;
    // Model missing.
    case 1002:
      return AsrErrorKind.modelMissing;
    // Recogniser busy / rate-limited.
    case 7: // SpeechRecognizer.ERROR_RECOGNIZER_BUSY.
      return AsrErrorKind.busy;
    // Timeout-ish network / matching failures.
    case 1: // SpeechRecognizer.ERROR_NETWORK_TIMEOUT.
    case 6: // SpeechRecognizer.ERROR_SERVER.
    case 8: // SpeechRecognizer.ERROR_NO_MATCH.
    case 9: // SpeechRecognizer.ERROR_SPEECH_TIMEOUT. NOTE: collides with
            // AsrService's legacy model-missing code; the native path wins
            // once P1-5 lands and that side moves to 1002.
      return AsrErrorKind.timeout;
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

/// One token-shaped payload from the LLM runtime. The Kotlin side stamps
/// every event with the [sessionId] the Dart caller chose via `startLlmGeneration`,
/// so this class filters on the way through.
class LlmStreamEvent {
  LlmStreamEvent({
    required this.sessionId,
    required this.type,
    required this.payload,
  });
  final String sessionId;
  final String type;
  final Map<Object?, Object?> payload;
}

/// Helper to bridge Kotlin event payloads into typed Dart objects for the
/// LLM runtime. The same trick as [NativeAsrEventDecoder]: events arrive as
/// `{'type': 'LLM_*', 'sessionId': '...', 'payload': {...}}`.
extension NativeLlmEventDecoder on Object? {
  /// Returns the event payload + session id if the frame is an LLM event,
  /// `null` for everything else (so a single listener can multiplex ASR,
  /// TTS and LLM frames without leaking each other's payloads).
  LlmStreamEvent? toLlmStreamEvent() {
    if (this is! Map) return null;
    final map = this as Map;
    if (map['type'] is! String) return null;
    final type = map['type'] as String;
    if (!type.startsWith('LLM_')) return null;
    final sessionId = (map['sessionId'] as String?) ?? '';
    final payloadRaw = map['payload'];
    final payload = payloadRaw is Map
        ? payloadRaw.cast<Object?, Object?>()
        : const <Object?, Object?>{};
    return LlmStreamEvent(
      sessionId: sessionId,
      type: type,
      payload: payload,
    );
  }
}
