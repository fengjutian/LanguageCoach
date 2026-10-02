import 'tts_models.dart';

/// Provider-agnostic TTS boundary. Implementations sit behind this interface
/// so the audio cache, queue and UI never touch concrete runtimes (Android
/// system TTS today, Qwen3-TTS in P1-3).
abstract interface class TtsEngine {
  /// Identifier surfaced to log files; never includes the device serial.
  String get id;

  /// Synthesise [request] into a playable audio file. Implementations are
  /// free to hit the network or call the local runtime, as long as they
  /// surface progress via [synthesisStream].
  Future<TtsResult> synthesize(TtsRequest request);

  /// Hot stream of synthesis progress events. UI can pipe this into a progress
  /// bar; the audio cache uses it to know when the file is ready.
  Stream<TtsSynthesisEvent> get synthesisStream;
}

sealed class TtsSynthesisEvent {
  const TtsSynthesisEvent();
}

class TtsSynthesisProgress extends TtsSynthesisEvent {
  const TtsSynthesisProgress(this.fraction);
  final double fraction; // 0..1
}

class TtsSynthesisComplete extends TtsSynthesisEvent {
  const TtsSynthesisComplete(this.result);
  final TtsResult result;
}

class TtsSynthesisFailed extends TtsSynthesisEvent {
  const TtsSynthesisFailed(this.error);
  final TtsError error;
}
