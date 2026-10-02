import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/asr_engine.dart';
import '../../../core/audio/audio_player.dart';
import 'speech_session_controller.dart';
import 'tts_controller.dart';

/// High-level session phase the chat UI uses to decide which control
/// surface to render (mic pulse, TTS loading bar, retry card, etc).
///
/// P2-1 folds the two existing controllers into one view so the chat
/// page doesn't have to read both providers and reconcile them locally.
/// Computing the phase from [SpeechSessionState] and [TtsPlaybackState]
/// also keeps a single source of truth — when either controller mutates,
/// the consumers rebuild exactly once.
enum ChatSessionPhase {
  /// Nothing in flight. Mic ready, no playback queued.
  idle,

  /// Microphone is capturing speech.
  recording,

  /// The ASR has produced a final transcript and the LLM / TTS pipeline is
  /// working on a reply. Tells the UI to show a "thinking" affordance.
  processing,

  /// TTS is playing the assistant reply back to the user.
  playing,

  /// Last action failed; the chat UI should render a retry card.
  error,
}

/// Computed session phase. Subscribes to [speechSessionControllerProvider]
/// and [ttsControllerProvider] and folds their state into one enum.
final chatSessionPhaseProvider = Provider<ChatSessionPhase>((ref) {
  final speech = ref.watch(speechSessionControllerProvider);
  final tts = ref.watch(ttsControllerProvider);

  if (speech.lastError != null) return ChatSessionPhase.error;
  if (speech.listening) return ChatSessionPhase.recording;

  // TTS is mid-flight — anything in `generating` / `loading` / `playing`
  // counts as a non-idle phase.
  if (tts.playback == AudioPlaybackState.loading ||
      tts.playback == AudioPlaybackState.playing ||
      tts.playback == AudioPlaybackState.error) {
    if (tts.playback == AudioPlaybackState.playing) {
      return ChatSessionPhase.playing;
    }
    if (tts.playback == AudioPlaybackState.error) {
      return ChatSessionPhase.error;
    }
    return ChatSessionPhase.processing;
  }
  if (tts.sentenceStates.values.any(
    (s) => s == SentencePlaybackState.generating,
  )) {
    return ChatSessionPhase.processing;
  }

  return ChatSessionPhase.idle;
});

/// Convenience projection: a typed error the UI can render directly,
/// instead of having to thread [AsrErrorKind] / [AudioPlaybackState.error]
/// through two layers. P2-1 keeps this light — full localisation / action
/// catalog lands once we have more failure modes in production.
class SessionError {
  const SessionError({
    required this.message,
    required this.retryable,
    this.kind,
  });

  /// Raw error kind when known. UI strings typically only need [message]
  /// but tests + the suggested-action engine still need the underlying
  /// classification.
  final AsrErrorKind? kind;

  /// Human-readable message suitable for direct display.
  final String message;

  /// True when retrying the same operation makes sense. Permission /
  /// unavailable errors flip this off because retrying without a fix is
  /// just noise.
  final bool retryable;
}

final chatSessionErrorProvider = Provider<SessionError?>((ref) {
  final speech = ref.watch(speechSessionControllerProvider);
  final tts = ref.watch(ttsControllerProvider);

  if (speech.lastError != null) {
    return SessionError(
      kind: speech.lastError,
      message: _asrMessage(speech.lastError!),
      retryable: speech.lastError != AsrErrorKind.permissionDenied &&
          speech.lastError != AsrErrorKind.unavailable,
    );
  }
  if (tts.playback == AudioPlaybackState.error) {
    return const SessionError(
      message: '音频播放失败。',
      retryable: true,
    );
  }
  return null;
});

String _asrMessage(AsrErrorKind kind) {
  switch (kind) {
    case AsrErrorKind.permissionDenied:
      return '麦克风权限被拒绝,请到系统设置中开启。';
    case AsrErrorKind.busy:
      return '识别器正忙,请稍候再试。';
    case AsrErrorKind.timeout:
      return '识别超时,请重新开始。';
    case AsrErrorKind.unavailable:
      return '当前设备无可用的语音识别引擎。';
    case AsrErrorKind.format:
      return '识别结果格式异常。';
    case AsrErrorKind.modelMissing:
      return '语音模型未安装,请前往设置页下载。';
    case AsrErrorKind.unknown:
      return '语音识别失败。';
  }
}