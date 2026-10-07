import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/minimax_tts_engine.dart';
import 'package:language_coach/core/audio/tts_models.dart';

/// Fake Dio adapter that captures the request and replies with a
/// configurable status + JSON body. Lives next to the engine under test
/// — production code wires real Dio instances from `tts_controller`.
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter({this.body, this.error});

  final Map<String, Object?>? body;
  final DioException? error;

  RequestOptions? lastRequest;
  Map<String, Object?>? lastBody;
  Map<String, Object?>? lastHeaders;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    lastHeaders = Map<String, Object?>.from(options.headers);
    if (requestStream != null) {
      // Drain the request body so the test can assert what was sent.
      await requestStream.fold<List<int>>([], (acc, chunk) => acc..addAll(chunk))
          .then((bytes) {
        if (bytes.isEmpty) return;
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) {
          lastBody = Map<String, Object?>.from(decoded);
        }
      });
    }
    final controller = StreamController<Uint8List>();
    if (error != null) throw error!;
    final responseBytes = body == null
        ? <int>[]
        : utf8.encode(jsonEncode(body));
    Future(() {
      controller.add(Uint8List.fromList(responseBytes));
      controller.close();
    });
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        Headers.contentLengthHeader: [responseBytes.length.toString()],
      },
    );
  }
}

String _hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Like [_ScriptedAdapter] but replies with a raw JSON string so the
/// adapter can drive `Map<dynamic, dynamic>` decoding — Dart Map literals
/// cannot be constructed with mixed key types.
class _RawJsonAdapter implements HttpClientAdapter {
  _RawJsonAdapter(this.body);

  final String body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final controller = StreamController<Uint8List>();
    final bytes = utf8.encode(body);
    Future(() {
      controller.add(Uint8List.fromList(bytes));
      controller.close();
    });
    return ResponseBody(
      controller.stream,
      200,
      headers: {
        Headers.contentLengthHeader: [bytes.length.toString()],
      },
    );
  }
}

void main() {
  group('MinimaxTtsEngine', () {
    late Directory tmp;
    late Directory cacheDir;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('minimax_tts_test_');
      cacheDir = Directory('${tmp.path}/cache');
    });

    tearDown(() async {
      if (tmp.existsSync()) {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    test('synthesize posts the MiniMax T2A v2 schema and decodes hex audio',
        () async {
      final audioBytes = <int>[0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00];
      final adapter = _ScriptedAdapter(
        body: {
          'data': {'audio': _hexEncode(audioBytes), 'status': 2},
          'extra_info': {
            'audio_length': 1234,
            'audio_sample_rate': 32000,
            'audio_format': 'mp3',
          },
          'base_resp': {'status_code': 0, 'status_msg': 'success'},
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      final result = await engine.synthesize(const TtsRequest(
        text: '你好，世界',
        language: 'zh-CN',
        voiceId: 'default',
        speed: 1.15,
      ));

      // Audio file landed on disk with the bytes we returned.
      expect(result.audioPath.endsWith('.mp3'), isTrue);
      expect(File(result.audioPath).existsSync(), isTrue);
      expect(File(result.audioPath).readAsBytesSync(), audioBytes);
      expect(result.format, 'mp3');
      expect(result.duration, const Duration(milliseconds: 1234));
      expect(result.bytes, audioBytes.length);

      // Request shape — every MiniMax T2A v2 field the engine fills.
      expect(adapter.lastRequest?.path, 'https://api.minimaxi.com/v1/t2a_v2');
      expect(adapter.lastHeaders?['Authorization'], 'Bearer sk-test');
      expect(adapter.lastHeaders?['Content-Type'], 'application/json');
      final body = adapter.lastBody!;
      expect(body['model'], 'speech-2.8-hd');
      expect(body['text'], '你好，世界');
      expect(body['stream'], false);
      expect(body['output_format'], 'hex');
      expect(body['language_boost'], 'Chinese');
      final voiceSetting = body['voice_setting']! as Map;
      expect(voiceSetting['voice_id'], 'male-qn-qingse');
      expect(voiceSetting['speed'], 1.15);
      final audioSetting = body['audio_setting']! as Map;
      expect(audioSetting['format'], 'mp3');
      expect(audioSetting['sample_rate'], 32000);
    });

    test('passes through a user-picked voice id instead of the language default',
        () async {
      final adapter = _ScriptedAdapter(
        body: {
          'data': {'audio': _hexEncode([0xAA, 0xBB]), 'status': 2},
          'extra_info': {'audio_format': 'mp3'},
          'base_resp': {'status_code': 0},
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await engine.synthesize(const TtsRequest(
        text: 'Hello there',
        language: 'en-US',
        voiceId: 'English_Graceful_Hearts',
        speed: 1.0,
      ));

      expect(
        (adapter.lastBody!['voice_setting']! as Map)['voice_id'],
        'English_Graceful_Hearts',
      );
    });

    test('maps a persisted engine-neutral voice id to a MiniMax voice',
        () async {
      final adapter = _ScriptedAdapter(
        body: {
          'data': {'audio': _hexEncode([0xAA, 0xBB]), 'status': 2},
          'extra_info': {'audio_format': 'mp3'},
          'base_resp': {'status_code': 0},
        },
      );
      final engine = MinimaxTtsEngine(
        dio: Dio()..httpClientAdapter = adapter,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await engine.synthesize(const TtsRequest(
        text: 'Hello there',
        language: 'en',
        voiceId: 'en_us_neutral',
      ));

      expect(
        (adapter.lastBody!['voice_setting']! as Map)['voice_id'],
        'male-qn-qingse',
      );
    });

    test('uses one verified multilingual voice and the correct language boost '
        'for every supported app language', () async {
      const expectedBoosts = <String, String>{
        'en': 'English',
        'ja': 'Japanese',
        'fr': 'French',
        'ko': 'Korean',
        'es': 'Spanish',
        'de': 'German',
        'it': 'Italian',
        'zh-CN': 'Chinese',
        'ru': 'Russian',
        'pt': 'Portuguese',
      };

      for (final entry in expectedBoosts.entries) {
        final adapter = _ScriptedAdapter(
          body: {
            'data': {'audio': _hexEncode([0xAA, 0xBB]), 'status': 2},
            'extra_info': {'audio_format': 'mp3'},
            'base_resp': {'status_code': 0},
          },
        );
        final engine = MinimaxTtsEngine(
          dio: Dio()..httpClientAdapter = adapter,
          apiKeyResolver: () async => 'sk-test',
          outputDirectory: cacheDir,
        );

        await engine.synthesize(TtsRequest(
          text: 'language test',
          language: entry.key,
          voiceId: '${entry.key}_neutral',
        ));

        expect(
          (adapter.lastBody!['voice_setting']! as Map)['voice_id'],
          'male-qn-qingse',
          reason: 'default voice for ${entry.key}',
        );
        expect(
          adapter.lastBody!['language_boost'],
          entry.value,
          reason: 'language boost for ${entry.key}',
        );
        await engine.dispose();
      }
    });

    test('maps legacy built-in voice ids to the verified system voice',
        () async {
      const legacyIds = <String>[
        'Chinese_Female_Sharp',
        'English_expressive_narrator',
        'English_Graceful_Hearts',
        'Japanese_Internet_Celebrity',
        'French_Female_News_Anchor',
      ];

      for (final legacyId in legacyIds) {
        final adapter = _ScriptedAdapter(
          body: {
            'data': {'audio': _hexEncode([0xAA, 0xBB]), 'status': 2},
            'extra_info': {'audio_format': 'mp3'},
            'base_resp': {'status_code': 0},
          },
        );
        final engine = MinimaxTtsEngine(
          dio: Dio()..httpClientAdapter = adapter,
          apiKeyResolver: () async => 'sk-test',
          outputDirectory: cacheDir,
        );

        await engine.synthesize(TtsRequest(
          text: 'legacy voice test',
          language: 'ja',
          voiceId: legacyId,
        ));

        expect(
          (adapter.lastBody!['voice_setting']! as Map)['voice_id'],
          'male-qn-qingse',
          reason: legacyId,
        );
        await engine.dispose();
      }
    });

    test('throws TtsError(engineUnavailable) when key is missing', () async {
      final adapter = _ScriptedAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => null,
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await expectLater(
        engine.synthesize(const TtsRequest(text: 'x', language: 'en')),
        throwsA(
          isA<TtsError>().having((e) => e.kind, 'kind',
              TtsErrorKind.engineUnavailable),
        ),
      );
      // And no HTTP call was made.
      expect(adapter.lastRequest, isNull);
    });

    test('surfaces TtsError(network) on a connection failure', () async {
      final adapter = _ScriptedAdapter(
        error: DioException(
          requestOptions: RequestOptions(path: '/v1/t2a_v2'),
          type: DioExceptionType.connectionError,
          message: 'no route',
        ),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await expectLater(
        engine.synthesize(const TtsRequest(text: 'x', language: 'en')),
        throwsA(
          isA<TtsError>()
              .having((e) => e.kind, 'kind', TtsErrorKind.network),
        ),
      );
    });

    test('surfaces TtsError(unknown) when MiniMax returns status_code != 0',
        () async {
      final adapter = _ScriptedAdapter(
        body: {
          'data': {'audio': '', 'status': 2},
          'base_resp': {
            'status_code': 1001,
            'status_msg': 'voice id not found',
          },
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await expectLater(
        engine.synthesize(const TtsRequest(text: 'x', language: 'en')),
        throwsA(
          isA<TtsError>()
              .having((e) => e.kind, 'kind', TtsErrorKind.unknown),
        ),
      );
    });

    test('surfaces TtsError(format) when MiniMax returns malformed hex',
        () async {
      final adapter = _ScriptedAdapter(
        body: {
          'data': {'audio': 'ffXX90zz', 'status': 2},
          'extra_info': {'audio_format': 'mp3'},
          'base_resp': {'status_code': 0},
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await expectLater(
        engine.synthesize(const TtsRequest(text: 'x', language: 'en')),
        throwsA(
          isA<TtsError>()
              .having((e) => e.kind, 'kind', TtsErrorKind.format),
        ),
      );
    });

    test('succeeds after the synthesis stream has been disposed', () async {
      final adapter = _ScriptedAdapter(
        body: {
          'data': {'audio': _hexEncode([0xAA, 0xBB]), 'status': 2},
          'extra_info': {'audio_format': 'mp3'},
          'base_resp': {'status_code': 0},
        },
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );

      // Provider rebuilds / cancellations tear down the synthesis stream
      // before the next call lands. The next synthesize must not raise
      // `Bad state: Cannot add new events after calling close`.
      await engine.dispose();

      final result = await engine.synthesize(
        const TtsRequest(text: 'post-dispose', language: 'en'),
      );
      expect(result.audioPath.endsWith('.mp3'), isTrue);
      expect(File(result.audioPath).existsSync(), isTrue);
    });

    test('surfaces TtsError(format) when the JSON body has a nested non-map '
        'where a map is expected', () async {
      // Hand-build a raw JSON body where `extra_info` is a String instead
      // of a Map — Dart jsonDecode happily returns a Map<dynamic, dynamic>
      // with a String value where the engine expects a nested map. The
      // cast walk must convert that to a typed TtsError instead of
      // letting the TypeError escape to the TTS pipeline.
      final adapter = _RawJsonAdapter(
        '{"data":{"audio":"deadbeef","status":2},'
        '"extra_info":[1,2,3],'
        '"base_resp":{"status_code":0}}',
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final engine = MinimaxTtsEngine(
        dio: dio,
        apiKeyResolver: () async => 'sk-test',
        outputDirectory: cacheDir,
      );
      addTearDown(engine.dispose);

      await expectLater(
        engine.synthesize(const TtsRequest(text: 'x', language: 'en')),
        throwsA(
          isA<TtsError>()
              .having((e) => e.kind, 'kind', TtsErrorKind.format),
        ),
      );
    });
  });
}
