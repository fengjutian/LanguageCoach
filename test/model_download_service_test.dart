import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/model_download_service.dart';
import 'package:language_coach/core/audio/model_manager.dart';
import 'package:language_coach/core/audio/model_manifest.dart';

/// Fake Dio adapter that records requests and emits a stream of bytes.
/// Two behaviours are exposed via [mode]:
///   * `success` — emits one chunk + closes cleanly.
///   * `paused`  — yields the first chunk then hangs; the test calls
///                 [ModelDownloadService.pause] and expects a paused event.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.mode = 'success'});

  final String mode;

  static const _defaultBody = <int>[
    0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80,
    0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0, 0x00,
  ];

  String? lastRangeHeader;
  bool requestClosed = false;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRangeHeader = options.headers['Range'] as String?;
    if (mode == 'paused') {
      final controller = StreamController<Uint8List>();
      // Yield the first chunk and then leave the stream open — the test
      // calls `service.pause(...)`, which cancels the underlying dio
      // request and surfaces a Paused event.
      controller.add(Uint8List.fromList(_defaultBody.sublist(0, 4)));
      return ResponseBody(
        controller.stream,
        200,
        headers: {
          Headers.contentLengthHeader: [_defaultBody.length.toString()],
        },
      );
    }
    final controller = StreamController<Uint8List>();
    Future(() {
      controller.add(Uint8List.fromList(_defaultBody));
      controller.close();
    });
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        Headers.contentLengthHeader: [_defaultBody.length.toString()],
      },
    );
  }
}

String _sha256Hex(List<int> bytes) =>
    sha256.convert(bytes).toString();

void main() {
  group('ModelDownloadService', () {
    late Directory tmp;
    late Directory root;
    late StreamController<ModelEvent> events;
    late List<ModelEvent> received;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('model_dl_test_');
      root = Directory('${tmp.path}/models');
      events = StreamController<ModelEvent>.broadcast();
      received = [];
      events.stream.listen(received.add);
    });

    tearDown(() async {
      await events.close();
      // Give the dio adapter a moment to release its handle on the temp
      // directory before we delete it.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {
          // best-effort — Windows can refuse the delete if a child stream
          // is still alive.
        }
      }
    });

    test('happy path emits Started → Progress → Verifying → Installed',
        () async {
      final adapter = _FakeAdapter();
      final dio = Dio(BaseOptions(headers: {'Accept': '*/*'}))
        ..httpClientAdapter = adapter;
      final service = ModelDownloadService(
        dio: dio,
        rootDirectory: root,
        events: events,
      );
      final manifest = ModelManifest(
        id: 'qwen3-tts-0.6B',
        type: 'tts',
        version: '0.6.0',
        label: 'Qwen3-TTS 0.6B',
        sizeBytes: _FakeAdapter._defaultBody.length,
        downloadUrl: 'https://example.invalid/qwen3-tts-0.6B.tar.gz',
        sha256: _sha256Hex(_FakeAdapter._defaultBody),
        artifacts: const <ModelArtifact>[],
      );

      final path = await service.download(manifest);
      expect(path, isNotNull);
      expect(File(path!).existsSync(), isTrue);
      expect(File('$path.partial').existsSync(), isFalse);

      // Verify the atomic install produced the expected SHA-256.
      final actual = await sha256.bind(File(path).openRead()).first;
      expect(actual.toString(), manifest.sha256);

      // Flush the broadcast stream listeners before we tally events.
      await Future<void>.delayed(Duration.zero);
      final types = received.map((e) => e.runtimeType).toList();
      expect(types, [
        ModelDownloadStarted,
        ModelDownloadProgress,
        ModelVerifying,
        ModelInstalled,
      ]);
    });

    test('pause mid-stream emits a Paused event and keeps the partial file',
        () async {
      final adapter = _FakeAdapter(mode: 'paused');
      final dio = Dio(BaseOptions())..httpClientAdapter = adapter;
      final service = ModelDownloadService(
        dio: dio,
        rootDirectory: root,
        events: events,
      );
      final manifest = ModelManifest(
        id: 'qwen3-tts-0.6B',
        type: 'tts',
        version: '0.6.0',
        sizeBytes: _FakeAdapter._defaultBody.length,
        downloadUrl: 'https://example.invalid/qwen3-tts-0.6B.tar.gz',
        sha256: 'placeholder',
        artifacts: const <ModelArtifact>[],
      );

      final downloadFuture = service.download(manifest);
      // Give the stream a tick to emit its first chunk.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await service.pause('qwen3-tts-0.6B');

      final path = await downloadFuture;
      expect(path, isNull);

      // Partial file exists with the bytes we wrote.
      final partial = File(
        '${root.path}/models/qwen3-tts-0.6B/0.6.0.partial',
      );
      expect(partial.existsSync(), isTrue);
      expect(partial.lengthSync(), greaterThan(0));

      // Flush the broadcast stream so the Paused event has been delivered
      // before we count it.
      await Future<void>.delayed(Duration.zero);
      expect(
        received.whereType<ModelDownloadPaused>().length,
        1,
      );
    });

    test('checksum mismatch produces Errored(checksumMismatch)', () async {
      final adapter = _FakeAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final service = ModelDownloadService(
        dio: dio,
        rootDirectory: root,
        events: events,
      );
      final manifest = ModelManifest(
        id: 'qwen3-tts-0.6B',
        type: 'tts',
        version: '0.6.0',
        sizeBytes: _FakeAdapter._defaultBody.length,
        downloadUrl: 'https://example.invalid/qwen3-tts-0.6B.tar.gz',
        sha256: 'DEADBEEF' * 8,
        artifacts: const <ModelArtifact>[],
      );
      final path = await service.download(manifest);
      expect(path, isNull);
      // Let the broadcast stream flush any remaining events before we
      // assert on them — broadcast streams drop events for late
      // listeners but `add` may be queued in microtasks.
      await Future<void>.delayed(Duration.zero);
      expect(
        received.whereType<ModelErrored>().first.kind,
        ModelErrorKind.checksumMismatch,
      );
    });
  });
}