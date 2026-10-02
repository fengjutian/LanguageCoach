import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/asr_engine.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/features/chat/application/chat_session_state.dart';
import 'package:language_coach/features/chat/application/speech_session_controller.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';

void main() {
  group('chatSessionPhaseProvider', () {
    test('idle when both controllers are quiet', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.idle);
    });

    test('recording when speech session is listening', () {
      final container = ProviderContainer(overrides: [
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
      final container = ProviderContainer(overrides: [
        speechSessionControllerProvider.overrideWith(
          () => _FakeSpeechSession(lastError: AsrErrorKind.busy),
        ),
      ]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.error);
    });

    test('playing when TTS is playing back', () {
      final container = ProviderContainer(overrides: [
        ttsControllerProvider.overrideWith(
          () => _FakeTtsController(playback: AudioPlaybackState.playing),
        ),
      ]);
      addTearDown(container.dispose);
      expect(container.read(chatSessionPhaseProvider), ChatSessionPhase.playing);
    });

    test('processing when TTS is mid-generation', () {
      final container = ProviderContainer(overrides: [
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
      final container = ProviderContainer(overrides: [
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
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(chatSessionErrorProvider), isNull);
    });

    test('permission denied is not retryable', () {
      final container = ProviderContainer(overrides: [
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
      final container = ProviderContainer(overrides: [
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