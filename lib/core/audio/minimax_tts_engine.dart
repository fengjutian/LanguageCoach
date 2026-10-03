import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'tts_engine.dart';
import 'tts_models.dart';

/// `TtsEngine` backed by the MiniMax T2A v2 cloud API
/// (`POST /v1/t2a_v2`). Synthesises audio via HTTP and writes the
/// decoded bytes to [outputDirectory]; no on-device model download is
/// required, so users who cannot or do not want to ship the ~860 MB
/// Qwen3-TTS GGUF can still get natural-sounding playback.
///
/// Requests carry a Bearer token resolved lazily on every call so the
/// engine can pick up a freshly-entered API key without rebuilding.
class MinimaxTtsEngine implements TtsEngine {
  MinimaxTtsEngine({
    required Dio dio,
    required Future<String?> Function() apiKeyResolver,
    required this.outputDirectory,
    // MiniMax API keys are region-bound. Language Coach's LLM endpoint uses
    // the mainland-China platform (api.minimaxi.com), so TTS must use the
    // matching host as well. Sending that key to api.minimax.io produces a
    // misleading `invalid api key` after the text reply has already loaded.
    String baseUrl = 'https://api.minimaxi.com/v1',
    String model = 'speech-2.6-hd',
    String? id,
  })  : _dio = dio,
        _apiKeyResolver = apiKeyResolver,
        _baseUrl = baseUrl,
        _model = model,
        id = id ?? 'minimax-tts';

  final Dio _dio;
  final Future<String?> Function() _apiKeyResolver;
  final Directory outputDirectory;
  final String _baseUrl;
  final String _model;
  @override
  final String id;

  final _controller = StreamController<TtsSynthesisEvent>.broadcast();

  @override
  Future<TtsResult> synthesize(TtsRequest request) async {
    final apiKey = await _apiKeyResolver();
    if (apiKey == null || apiKey.isEmpty) {
      throw const TtsError(
        TtsErrorKind.engineUnavailable,
        'MiniMax API key not configured',
      );
    }
    try {
      final response = await _dio.post<List<int>>(
        '$_baseUrl/t2a_v2',
        data: _buildRequestBody(request),
        options: Options(
          headers: {
            'Authorization': 'Bearer $apiKey',
            'Content-Type': 'application/json',
          },
          // Pull the body ourselves so the JSON parser does not depend on
          // dio's content-type sniffing — the MiniMax endpoint always
          // replies with `application/json` but the in-memory test
          // adapter cannot drive dio's interceptor cleanly otherwise.
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
      final rawBytes = response.data;
      final Map<String, Object?> data;
      try {
        final dynamic decoded = jsonDecode(utf8.decode(rawBytes ?? <int>[]));
        if (decoded is! Map) {
          throw const TtsError(
            TtsErrorKind.format,
            'MiniMax returned a non-object body',
          );
        }
        // Cast through `dynamic` so a Map with non-String keys (or a
        // nested Map<int,Object?>) surfaces as a typed TtsError instead
        // of an uncaught TypeError bubbling up to the TTS pipeline.
        data = _castJsonMap(decoded);
      } on TtsError {
        rethrow;
      } on FormatException catch (e) {
        throw TtsError(
          TtsErrorKind.format,
          'MiniMax returned malformed JSON: ${e.message}',
        );
      } on TypeError catch (e) {
        throw TtsError(
          TtsErrorKind.format,
          'MiniMax returned an unexpected payload shape: ${e.toString()}',
        );
      }
      final baseResp = data['base_resp'];
      if (baseResp is Map && (baseResp['status_code'] ?? -1) != 0) {
        throw TtsError(
          TtsErrorKind.unknown,
          'MiniMax error: ${baseResp['status_msg'] ?? 'unknown'}',
        );
      }
      final payload = data['data'];
      final audioHex = payload is Map ? payload['audio'] : null;
      if (audioHex is! String || audioHex.isEmpty) {
        throw const TtsError(
          TtsErrorKind.format,
          'MiniMax returned no audio data',
        );
      }
      final bytes = _hexDecode(audioHex);
      final extraInfo = data['extra_info'];
      final audioFormat = extraInfo is Map
          ? (extraInfo['audio_format'] as String? ?? 'mp3')
          : 'mp3';
      final audioLengthMs =
          extraInfo is Map ? (extraInfo['audio_length'] as int? ?? 0) : 0;
      if (!outputDirectory.existsSync()) {
        outputDirectory.createSync(recursive: true);
      }
      final fileName = '${request.cacheKey().hashCode}.$audioFormat';
      final outPath = '${outputDirectory.path}/$fileName';
      await File(outPath).writeAsBytes(bytes, flush: true);
      final result = TtsResult(
        audioPath: outPath,
        bytes: bytes.length,
        format: audioFormat,
        duration: Duration(milliseconds: audioLengthMs),
      );
      // The synthesis stream might be torn down between fetch and write
      // (provider rebuild, user cancellation) — drop the event instead
      // of letting `add` raise `Bad state: Cannot add new events after
      // calling close`. The TtsResult still goes back to the caller, so
      // the audio file is usable.
      if (!_controller.isClosed) {
        _controller.add(TtsSynthesisComplete(result));
      }
      return result;
    } on DioException catch (e) {
      throw TtsError(_mapDioKind(e), e.message ?? 'MiniMax network failure');
    }
  }

  Map<String, Object?> _buildRequestBody(TtsRequest request) {
    // Treat the `default` sentinel as a request for the language default
    // voice — the user-facing picker writes real voice ids (MiniMax
    // strings) into [AppSettings.selectedVoices], so anything else is a
    // safe pass-through.
    final voiceId = request.voiceId.isEmpty || request.voiceId == 'default'
        ? _defaultVoiceFor(request.language)
        : request.voiceId;
    return {
      'model': _model,
      'text': request.text,
      'stream': false,
      'output_format': 'hex',
      'voice_setting': {
        'voice_id': voiceId,
        'speed': request.speed,
        'vol': 1.0,
        'pitch': 0,
      },
      'audio_setting': {
        'format': 'mp3',
        'sample_rate': 32000,
        'bitrate': 128000,
      },
      'language_boost': _languageBoost(request.language),
    };
  }

  String _defaultVoiceFor(String languageCode) {
    switch (languageCode) {
      case 'zh-CN':
      case 'zh':
        return 'Chinese_Female_Sharp';
      case 'en-US':
      case 'en':
        return 'English_expressive_narrator';
      case 'ja-JP':
      case 'ja':
        return 'Japanese_Internet_Celebrity';
      case 'fr-FR':
      case 'fr':
        return 'French_Female_News_Anchor';
      default:
        return 'English_expressive_narrator';
    }
  }

  String _languageBoost(String languageCode) {
    if (languageCode.isEmpty) return 'auto';
    final head = languageCode.substring(0, 2).toLowerCase();
    switch (head) {
      case 'zh':
        return 'Chinese';
      case 'en':
        return 'English';
      case 'ja':
        return 'Japanese';
      case 'fr':
        return 'French';
      case 'ko':
        return 'Korean';
      case 'es':
        return 'Spanish';
      case 'de':
        return 'German';
      case 'it':
        return 'Italian';
      case 'ru':
        return 'Russian';
      case 'pt':
        return 'Portuguese';
      default:
        return 'auto';
    }
  }

  Uint8List _hexDecode(String hex) {
    // MiniMax occasionally returns a truncated or otherwise malformed hex
    // payload (e.g. a partial frame when the connection is reset). Wrap
    // the parse so the engine surfaces a typed [TtsError] instead of an
    // uncaught FormatException / RangeError bubbling up to the UI.
    try {
      final length = hex.length;
      final out = Uint8List(length ~/ 2);
      for (var i = 0; i + 1 < length; i += 2) {
        out[i ~/ 2] = int.parse(hex.substring(i, i + 2), radix: 16);
      }
      return out;
    } on FormatException catch (e) {
      throw TtsError(
        TtsErrorKind.format,
        'MiniMax returned malformed hex audio (${e.message})',
      );
    } on RangeError catch (e) {
      throw TtsError(
        TtsErrorKind.format,
        'MiniMax returned truncated hex audio (${e.message})',
      );
    }
  }

  /// Walk a decoded JSON map (which Dart parses as `Map<dynamic, dynamic>`)
  /// and rebuild it as `Map<String, Object?>`. Nested maps are cast
  /// recursively; non-String keys or values that cannot be coerced raise
  /// a [TypeError] that the call site maps to [TtsErrorKind.format].
  Map<String, Object?> _castJsonMap(dynamic value) {
    if (value is! Map) {
      throw TypeError();
    }
    final result = <String, Object?>{};
    value.forEach((key, v) {
      if (key is! String) {
        throw TypeError();
      }
      if (v == null) {
        result[key] = null;
      } else if (v is Map) {
        result[key] = _castJsonMap(v);
      } else if (v is num || v is String || v is bool) {
        result[key] = v;
      } else {
        throw TypeError();
      }
    });
    return result;
  }

  TtsErrorKind _mapDioKind(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return TtsErrorKind.network;
      case DioExceptionType.cancel:
        return TtsErrorKind.cancelled;
      case DioExceptionType.badResponse:
        final status = e.response?.statusCode ?? 0;
        if (status == 401 || status == 403) {
          return TtsErrorKind.engineUnavailable;
        }
        return TtsErrorKind.unknown;
      default:
        return TtsErrorKind.unknown;
    }
  }

  @override
  Stream<TtsSynthesisEvent> get synthesisStream => _controller.stream;

  Future<void> dispose() => _controller.close();
}
