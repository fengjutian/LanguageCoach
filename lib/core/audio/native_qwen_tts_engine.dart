import 'dart:async';
import 'dart:io';

import 'package:language_coach/core/audio/tts_engine.dart';
import 'package:language_coach/core/audio/tts_models.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';
import 'package:language_coach/core/network/api_client.dart';

/// `TtsEngine` backed by the Kotlin native Qwen3-TTS runtime. Calls land
/// on the existing MethodChannel via [NativeAiBridge]; the runtime
/// orchestrates the JNI bindings.
///
/// On a host VM (tests) the bridge is a fake; on Android it routes to the
/// real `TtsService` in `MainActivity.kt`. Either way the audio file lands
/// at the path returned by the bridge, which Flutter then hands to the
/// audio cache.
class NativeQwenTtsEngine implements TtsEngine {
  NativeQwenTtsEngine({
    required NativeAiBridge bridge,
    required this.modelId,
    String? id,
  })  : _bridge = bridge,
        id = id ?? 'native-qwen-tts';

  final NativeAiBridge _bridge;
  final String modelId;
  @override
  final String id;

  final _controller = StreamController<TtsSynthesisEvent>.broadcast();

  /// `_controller.add` on a closed controller throws `Bad state`, and the
  /// catch-all below used to turn that into `TtsError(unknown, 'Bad state:
  /// …')` — so a WAV that had been written successfully was reported to the
  /// user as a synthesis failure whenever the engine was disposed (engine
  /// switch, API-key change) while a synthesis was still in flight.
  void _emit(TtsSynthesisEvent event) {
    if (_controller.isClosed) return;
    _controller.add(event);
  }

  @override
  Future<TtsResult> synthesize(TtsRequest request) async {
    try {
      final path = await _bridge.synthesize(
        text: request.text,
        language: request.language,
        voice: request.voiceId,
        speed: request.speed,
        model: modelId,
      );
      if (path == null || path.isEmpty) {
        final err = TtsError(TtsErrorKind.engineUnavailable,
            'native runtime returned no audio path');
        _emit(TtsSynthesisFailed(err));
        throw err;
      }
      final file = File(path);
      if (!file.existsSync()) {
        final err = TtsError(TtsErrorKind.format,
            'native runtime wrote to a missing file: $path');
        _emit(TtsSynthesisFailed(err));
        throw err;
      }
      _emit(TtsSynthesisComplete(TtsResult(
        audioPath: path,
        format: 'wav',
        bytes: file.lengthSync(),
      )));
      return TtsResult(
        audioPath: path,
        format: 'wav',
        bytes: file.lengthSync(),
      );
    } on LlmError catch (e) {
      throw TtsError(_mapKind(e.kind), e.message);
    } on TtsError {
      rethrow;
    } catch (e) {
      throw TtsError(TtsErrorKind.unknown, e.toString());
    }
  }

  @override
  Stream<TtsSynthesisEvent> get synthesisStream => _controller.stream;

  Future<void> dispose() => _controller.close();

  TtsErrorKind _mapKind(LlmErrorKind k) {
    switch (k) {
      case LlmErrorKind.network:
        return TtsErrorKind.network;
      case LlmErrorKind.format:
        return TtsErrorKind.format;
      case LlmErrorKind.cancelled:
        return TtsErrorKind.cancelled;
      case LlmErrorKind.server:
        return TtsErrorKind.engineUnavailable;
      default:
        return TtsErrorKind.unknown;
    }
  }
}
