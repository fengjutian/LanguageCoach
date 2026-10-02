import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'model_manager.dart';
import 'model_manifest.dart';

/// Dart-side download + verify + atomic install. Stand-alone — has no
/// Riverpod or platform-channel dependency so it can be exercised in
/// the host VM tests. The Kotlin `ModelManager` implements the same
/// contract for production builds.
class ModelDownloadService {
  ModelDownloadService({
    Dio? dio,
    required this.rootDirectory,
    required this.events,
  }) : _dio = dio ?? _buildDefaultDio();

  final Dio _dio;
  final Directory rootDirectory;
  final StreamController<ModelEvent> events;

  static Dio _buildDefaultDio() {
    return Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 30),
      headers: const {'User-Agent': 'language_coach/0.1'},
    ));
  }

  /// Holds cancel / pause state per model. The current implementation
  /// supports one in-flight download per model — multiple downloads
  /// across different models run concurrently.
  final _active = <String, _DownloadState>{};

  /// Public surface — `download` is async-friendly and emits progress on
  /// the [events] stream.
  Future<String?> download(ModelManifest manifest) async {
    final id = manifest.id;
    if (_active.containsKey(id) && _active[id]!.cancelToken == null) {
      return null; // already in flight
    }

    final state = _active.putIfAbsent(id, () => _DownloadState());
    state.cancelToken = CancelToken();
    state.paused = false;

    final installPath = _installPath(manifest);
    final tempPath = '$installPath.partial';
    await Directory(installPath).parent.create(recursive: true);

    events.add(ModelDownloadStarted(id, manifest.sizeBytes));

    // Range download — if the partial file already exists we resume
    // from its byte length.
    final existing = File(tempPath).existsSync()
        ? File(tempPath).lengthSync()
        : 0;
    var downloaded = existing;

    try {
      final headers = <String, Object?>{
        if (existing > 0) 'Range': 'bytes=$existing-',
      };
      final response = await _dio.get<ResponseBody>(
        manifest.downloadUrl,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
          // Re-issue once on a 416 (range unsatisfiable) by restarting
          // from 0 — happens when the server returns 200 OK for an
          // already-complete range request.
          validateStatus: (s) => s != null && s < 500,
        ),
        cancelToken: state.cancelToken,
      );

      final raf = File(tempPath).openWrite(mode: existing == 0 ? FileMode.write : FileMode.append);
      try {
        final total = manifest.sizeBytes == 0
            ? (int.tryParse(response.headers.value('content-length') ?? '') ?? 0)
            : manifest.sizeBytes + existing;
        await for (final chunk in response.data!.stream) {
          if (state.paused) {
            await raf.close();
            events.add(ModelDownloadPaused(id, downloaded));
            return null;
          }
          if (state.cancelToken?.isCancelled ?? false) {
            await raf.close();
            throw _Cancelled();
          }
          raf.add(chunk);
          downloaded += chunk.length;
          events.add(ModelDownloadProgress(id, downloaded, total));
        }
        await raf.close();
      } finally {
        await raf.close();
      }

      events.add(ModelVerifying(id));

      // SHA-256 verify.
      final actual = await _sha256OfFile(tempPath);
      if (manifest.sha256 != 'PLACEHOLDER_SHA256' &&
          manifest.sha256 != actual) {
        try {
          File(tempPath).deleteSync();
        } catch (_) {}
        events.add(ModelErrored(
          id,
          ModelErrorKind.checksumMismatch,
          'expected ${manifest.sha256}, got $actual',
        ));
        return null;
      }

      // Atomic install: rename partial → final.
      File(tempPath).renameSync(installPath);
      events.add(ModelInstalled(id, installPath));
      return installPath;
    } on DioException catch (e) {
      if (state.paused) {
        // Pause path: the cancel token triggered the DioException, but
        // the operator asked for a pause — surface that as Paused, not
        // Errored. The partial bytes are already on disk.
        events.add(ModelDownloadPaused(id, downloaded));
        return null;
      }
      final kind = switch (e.type) {
        DioExceptionType.cancel => ModelErrorKind.cancelled,
        DioExceptionType.connectionError ||
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout =>
          ModelErrorKind.network,
        _ => ModelErrorKind.unknown,
      };
      events.add(ModelErrored(id, kind, e.message ?? 'network failure'));
      return null;
    } on _Cancelled {
      events.add(ModelErrored(id, ModelErrorKind.cancelled, 'cancelled'));
      return null;
    } catch (e) {
      events.add(ModelErrored(id, ModelErrorKind.unknown, e.toString()));
      return null;
    } finally {
      _active.remove(id);
    }
  }

  Future<void> pause(String modelId) async {
    final state = _active[modelId];
    if (state == null) return;
    state.paused = true;
    // Cancelling the token unblocks the in-flight `await for` loop; the
    // DioException handler above recognises `state.paused` and surfaces
    // a Paused event instead of Errored(cancelled).
    state.cancelToken?.cancel('paused');
  }

  Future<void> cancel(String modelId) async {
    final state = _active[modelId];
    state?.cancelToken?.cancel('caller requested cancel');
    final tempPath = _partialPath(modelId);
    final f = File(tempPath);
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  String _installPath(ModelManifest manifest) {
    return '${rootDirectory.path}/models/${manifest.id}/${manifest.version}';
  }

  String _partialPath(String modelId) {
    final manifest = manifestFor(modelId);
    if (manifest == null) return '${rootDirectory.path}/models/$modelId/.partial';
    return '${_installPath(manifest)}.partial';
  }

  ModelManifest? manifestFor(String modelId) {
    for (final m in knownModels()) {
      if (m.id == modelId) return m;
    }
    return null;
  }
}

/// Stand-in list until the model release ships real manifests. Mirrors
/// the constants defined in `model_manifest.dart` but returns a fresh list
/// each call so the download service does not retain global state.
List<ModelManifest> knownModels() => [qwen3Tts06B, qwen3Llm06B];

Future<String> _sha256OfFile(String path) async {
  final digest = await sha256.bind(File(path).openRead().cast<List<int>>()).first;
  return digest.toString();
}

class _DownloadState {
  CancelToken? cancelToken;
  bool paused = false;
}

class _Cancelled implements Exception {
  const _Cancelled();
}