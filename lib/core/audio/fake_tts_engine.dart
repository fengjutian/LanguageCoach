import 'dart:async';
import 'dart:io';

import 'tts_engine.dart';
import 'tts_models.dart';

/// Off-platform TTS stub used until Android system TTS / Qwen3-TTS lands.
/// Writes an empty WAV file at the requested path so downstream pipeline
/// (cache + player) can verify the contract end-to-end without synthesising
/// real audio.
class FakeTtsEngine implements TtsEngine {
  FakeTtsEngine({required this.outputDirectory});
  final Directory outputDirectory;

  final _controller = StreamController<TtsSynthesisEvent>.broadcast();

  @override
  String get id => 'fake-tts';

  @override
  Future<TtsResult> synthesize(TtsRequest request) async {
    if (!outputDirectory.existsSync()) {
      outputDirectory.createSync(recursive: true);
    }
    final filename = '${request.cacheFileBaseName()}.wav';
    final path = '${outputDirectory.path}/$filename';
    final file = File(path);
    if (!file.existsSync()) {
      // 44 bytes of RIFF/WAV header pointing at zero PCM data — just enough
      // for [AudioPlayerService.load] to succeed without choking.
      file.writeAsBytesSync(_emptyWavHeader);
    }
    if (!_controller.isClosed) {
      _controller.add(TtsSynthesisComplete(TtsResult(
        audioPath: path,
        bytes: _emptyWavHeader.length,
        format: 'wav',
      )));
    }
    return TtsResult(
      audioPath: path,
      bytes: _emptyWavHeader.length,
      format: 'wav',
    );
  }

  @override
  Stream<TtsSynthesisEvent> get synthesisStream => _controller.stream;

  Future<void> dispose() => _controller.close();

  static const List<int> _emptyWavHeader = <int>[
    0x52, 0x49, 0x46, 0x46, // "RIFF"
    0x24, 0x00, 0x00, 0x00, // chunk size
    0x57, 0x41, 0x56, 0x45, // "WAVE"
    0x66, 0x6d, 0x74, 0x20, // "fmt "
    0x10, 0x00, 0x00, 0x00, // subchunk size
    0x01, 0x00, 0x01, 0x00, // PCM, mono
    0x44, 0xac, 0x00, 0x00, // sample rate 44100
    0x88, 0x58, 0x01, 0x00, // byte rate
    0x02, 0x00, 0x10, 0x00, // block align, bits per sample
    0x64, 0x61, 0x74, 0x61, // "data"
    0x00, 0x00, 0x00, 0x00, // data size
  ];
}
