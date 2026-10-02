import 'dart:async';

import 'asr_model_profile.dart';

/// A single 16-bit signed mono PCM frame slice — the smallest unit the
/// audio pipeline passes between layers. The pipeline guarantees one
/// channel, 16 kHz, little-endian; the VAD + ASR engines are calibrated
/// for that.
class PcmFrame {
  const PcmFrame(this.samples, {this.timestamp});
  final List<int> samples;
  final DateTime? timestamp;
}

/// Stream of [PcmFrame]s. Implementations sit on top of Android's
/// `AudioRecord` (or the test fake). All downstream consumers
/// (VAD / streaming ASR / waveform analyser) subscribe to the same stream.
abstract interface class AudioCaptureService {
  Stream<PcmFrame> get frameStream;
  Future<void> start({required Duration frameDuration});
  Future<void> stop();
}

/// Voice-activity detection. Real impl is a sherpa-onnx VAD; the in-memory
/// test impl always reports `speech`.
abstract interface class VadEngine {
  Stream<VadEvent> get eventStream;

  /// Feed the VAD with the same PCM frames the ASR sees. The VAD is
  /// stateless — it just classifies windows of input.
  void feed(PcmFrame frame);

  /// Triggered when the user pauses longer than [silenceTimeoutMs] while
  /// the VAD still considers them as speaking — the runtime fires this so
  /// the UI can auto-stop.
  Future<void> dispose();
}

sealed class VadEvent {
  const VadEvent();
}

class VadSpeechStart extends VadEvent {
  const VadSpeechStart();
}

class VadSpeechEnd extends VadEvent {
  const VadSpeechEnd();
}

class VadSilenceTimeout extends VadEvent {
  const VadSilenceTimeout(this.elapsedMs);
  final int elapsedMs;
}

/// One streaming ASR backend. Implementations include sherpa-onnx
/// (zipformer / whisper) and the system `SpeechRecognizer` fallback.
abstract interface class AsrEngine {
  /// Identifier surfaced to logs; never includes the device serial.
  String get id;

  /// True if the engine has a model resident and can stream results.
  bool get isReady;

  Stream<AsrResult> get resultStream;

  /// Feed the engine a frame of PCM. The engine buffers internally and
  /// emits partial / final results on [resultStream] at its own pace.
  void feed(PcmFrame frame);

  /// Force the current buffered audio to be flushed as a final result.
  /// Returns `true` if a final result was emitted synchronously, `false`
  /// if the engine still needs more audio to confirm.
  Future<bool> forceFinal();

  Future<void> reset();
  Future<void> dispose();
}

sealed class AsrResult {
  const AsrResult();
}

/// Partial decode — the engine is still listening and may revise.
class AsrPartial extends AsrResult {
  const AsrPartial(this.text);
  final String text;
}

/// Final decode — the engine considers the utterance complete.
class AsrFinal extends AsrResult {
  const AsrFinal(this.text, this.languageCode);
  final String text;
  final String languageCode;
}

/// Terminal failure — surfaced to the UI as an error card. Mirrors the
/// ASR_* event payloads the Kotlin side already emits.
enum AsrErrorKind {
  unavailable,
  permissionDenied,
  busy,
  modelMissing,
  timeout,
  format,
  unknown
}

class AsrFailure extends AsrResult {
  const AsrFailure(this.kind, this.message);
  final AsrErrorKind kind;
  final String message;
}

/// Load / unload hooks the runtime uses to swap ASR profiles. Real impl
/// lives behind [NativeAiBridge]; tests inject a fake.
abstract interface class AsrModelRegistry {
  Future<AsrModelProfile?> load(AsrModelProfile profile);
  Future<void> unload(String profileId);
  List<AsrModelProfile> installedProfiles();
}
