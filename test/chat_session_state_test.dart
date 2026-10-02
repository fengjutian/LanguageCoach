import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/asr_engine.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';
import 'package:language_coach/features/chat/application/chat_session_state.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/chat/application/speech_session_controller.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';

class _SilentBridge implements NativeAiBridge {
  @override
  Stream<Object?> get eventStream => const Stream.empty();

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

/// TTSController transitively reads `audioPlayerServiceProvider`, which
/// throws by default. The chat-page tests cover this in widget_test.dart;
/// here we just override it with the in-memory implementation so the
/// computed session providers can be exercised standalone.
ProviderContainer _container(List<Override> overrides) {
  return ProviderContainer(overrides: [
    audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
    // The real bridge tries to open an EventChannel which needs a test
    // binding — swap in a no-op bridge so the SpeechSessionController
    // can listen without touching the platform layer.
    nativeAiBridgeProvider.overrideWithValue(_SilentBridge()),
    ...overrides,
  ]);
}

void main() {
  group('chatSessionPhaseProvider', () {
    test('idle when both controllers are quiet', () {
      final container = _container([]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.idle);
    });

    test('recording when speech session is listening', () {
      final container = _container([
        speechSessionControllerProvider.overrideWith(
          () => _FakeSpeechSession(listening: true),
        ),
      ]);
      addTearDown(container.dispose);
      expect(
        container.read(chatSessionPhaseProvider),
        ChatSessionPhase.recording,
      );
    });

    test('error when speech session reports an error', () {
      final container = _container([
        speechSessionControllerProvider.overrideWith(
          () => _FakeSpeechSession(lastError: AsrErrorKind.busy),
        ),
      ]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.error);
    });

    test('playing when TTS is playing back', () {
      final container = _container([
        ttsControllerProvider.overrideWith(
          () => _FakeTtsController(playback: AudioPlaybackState.playing),
        ),
      ]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.playing);
    });

    test('processing when TTS is mid-generation', () {
      final container = _container([
        ttsControllerProvider.overrideWith(
          () => _FakeTtsController(playback: AudioPlaybackState.loading),
        ),
      ]);
      addTearDown(container.dispose);
      expect(
        container.read(chatSessionPhaseProvider),
        ChatSessionPhase.processing,
      );
    });

    test('error wins over playing when speech + tts both fire', () {
      final container = _container([
        speechSessionControllerProvider.overrideWith(
          () => _FakeSpeechSession(lastError: AsrErrorKind.permissionDenied),
        ),
        ttsControllerProvider.overrideWith(
          () => _FakeTtsController(playback: AudioPlaybackState.playing),
        ),
      ]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.error);
    });
  });

  group('chatSessionErrorProvider', () {
    test('null in the happy path', () {
      final container = _container([]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionErrorProvider), isNull);
    });

    test('permission denied is not retryable', () {
      final container = _container([
        speechSessionControllerProvider.overrideWith(
          () => _FakeSpeechSession(lastError: AsrErrorKind.permissionDenied),
        ),
      ]);
      addTearDown(container.dispose);
      final err = container.read(chatSessionErrorProvider)!;
      expect(err.retryable, isFalse);
      expect(err.kind, AsrErrorKind.permissionDenied);
    });

    test('busy is retryable with a localised message', () {
      final container = _container([
        speechSessionControllerProvider.overrideWith(
          () => _FakeSpeechSession(lastError: AsrErrorKind.busy),
        ),
      ]);
      addTearDown(container.dispose);
      final err = container.read(chatSessionErrorProvider)!;
      expect(err.retryable, isTrue);
      expect(err.message, contains('正忙'));
    });
  });
}

class _FakeSpeechSession extends SpeechSessionController {
  _FakeSpeechSession({
    this.listening = false,
    this.lastError,
  });
  final bool listening;
  final AsrErrorKind? lastError;

  @override
  SpeechSessionState build() => SpeechSessionState(
        listening: listening,
        partialText: '',
        lastError: lastError,
        engineReady: true,
        activeProfile: null,
      );
}

class _FakeTtsController extends TtsController {
  _FakeTtsController({this.playback = AudioPlaybackState.idle});
  final AudioPlaybackState playback;

  @override
  TtsPlaybackState build() => TtsPlaybackState(playback: playback);
}