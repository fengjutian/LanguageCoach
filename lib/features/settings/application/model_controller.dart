import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/model_download_service.dart';
import '../../../core/audio/model_manager.dart';
import '../../../core/audio/model_manifest.dart';

/// One row in the model manager table. Joined from
/// [ModelManifest] (declarative) + the disk state (where the partial
/// lives + the current [ModelDownloadStatus]).
class ModelEntry {
  ModelEntry({
    required this.manifest,
    required this.status,
    required this.localPath,
    required this.bytesDownloaded,
    required this.bytesTotal,
  });

  final ModelManifest manifest;
  final ModelDownloadStatus status;
  final String? localPath;
  final int bytesDownloaded;
  final int bytesTotal;

  double get progress => bytesTotal == 0 ? 0 : bytesDownloaded / bytesTotal;
}

final modelDownloadServiceProvider = Provider<ModelDownloadService?>((ref) {
  return null;
});

final modelManagerProvider = Provider<ModelManager?>((ref) {
  return null;
});

/// State surface for the model manager UI.
class ModelListState {
  ModelListState({
    required this.entries,
    required this.lastEvent,
  });

  final List<ModelEntry> entries;
  final ModelEvent? lastEvent;

  ModelListState copyWith({
    List<ModelEntry>? entries,
    ModelEvent? lastEvent,
  }) {
    return ModelListState(
      entries: entries ?? this.entries,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}

final modelControllerProvider =
    NotifierProvider<ModelController, ModelListState>(ModelController.new);

class ModelController extends Notifier<ModelListState> {
  StreamSubscription<ModelEvent>? _eventSub;

  @override
  ModelListState build() {
    final service = ref.watch(modelDownloadServiceProvider);
    final manager = ref.watch(modelManagerProvider);
    // Cancel the previous subscription before replacing it — otherwise
    // every rebuild stacks a new listener and every event fires N times.
    _eventSub?.cancel();
    _eventSub = null;
    if (manager != null) {
      _eventSub = manager.events.listen(_onEvent);
    } else if (service != null) {
      _eventSub = service.events.stream.listen(_onEvent);
    }
    ref.onDispose(() => _eventSub?.cancel());
    final entries =
        (manager?.installedModels() ?? const <InstalledModelRecord>[])
            .map(_toEntry)
            .toList();
    return ModelListState(entries: entries, lastEvent: null);
  }

  Future<void> download(String modelId) async {
    final service = ref.read(modelDownloadServiceProvider);
    final manager = ref.read(modelManagerProvider);
    final manifest =
        (service?.manifestFor(modelId)) ?? (manager?.manifestFor(modelId));
    if (manifest == null) return;
    if (service != null) {
      await service.download(manifest);
    } else {
      await manager?.download(modelId);
    }
    _refreshEntries();
  }

  Future<void> pause(String modelId) async {
    final service = ref.read(modelDownloadServiceProvider);
    if (service != null) {
      await service.pause(modelId);
    } else {
      await ref.read(modelManagerProvider)?.pause(modelId);
    }
    _refreshEntries();
  }

  Future<void> resume(String modelId) async {
    final service = ref.read(modelDownloadServiceProvider);
    final manager = ref.read(modelManagerProvider);
    if (manager != null) {
      await manager.resume(modelId);
    } else if (service != null) {
      // Re-issue the download — the service auto-resumes from the partial
      // file via HTTP Range.
      await download(modelId);
    }
    _refreshEntries();
  }

  Future<void> cancel(String modelId) async {
    final service = ref.read(modelDownloadServiceProvider);
    if (service != null) {
      await service.cancel(modelId);
    } else {
      await ref.read(modelManagerProvider)?.cancel(modelId);
    }
    _refreshEntries();
  }

  Future<bool> verify(String modelId) async {
    final manager = ref.read(modelManagerProvider);
    final service = ref.read(modelDownloadServiceProvider);
    final ok = manager != null
        ? await manager.verify(modelId)
        : await _verifyLocally(modelId, service);
    _refreshEntries();
    return ok;
  }

  Future<void> delete(String modelId) async {
    final manager = ref.read(modelManagerProvider);
    final service = ref.read(modelDownloadServiceProvider);
    if (manager != null) {
      await manager.delete(modelId);
    } else if (service != null) {
      final partial = '${service.rootDirectory.path}/models/$modelId';
      final dir = Directory(partial);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
    _refreshEntries();
  }

  Future<bool> load(String modelId) async {
    final manager = ref.read(modelManagerProvider);
    if (manager == null) return false;
    final ok = await manager.load(modelId);
    _refreshEntries();
    return ok;
  }

  Future<void> unload(String modelId) async {
    final manager = ref.read(modelManagerProvider);
    await manager?.unload(modelId);
    _refreshEntries();
  }

  void _onEvent(ModelEvent event) {
    state = state.copyWith(lastEvent: event);
    _refreshEntries();
  }

  void _refreshEntries() {
    final manager = ref.read(modelManagerProvider);
    final records =
        manager?.installedModels() ?? const <InstalledModelRecord>[];
    state = state.copyWith(entries: records.map(_toEntry).toList());
  }

  ModelEntry _toEntry(InstalledModelRecord record) {
    final manifest = _manifestFor(record.id);
    final last = state.lastEvent;
    final bytesTotal = manifest?.sizeBytes ?? record.sizeBytes;
    final downloaded =
        last is ModelDownloadProgress && last.modelId == record.id
            ? last.bytesDownloaded
            : (record.status == ModelDownloadStatus.installed ||
                    record.status == ModelDownloadStatus.loaded)
                ? bytesTotal
                : 0;
    return ModelEntry(
      manifest: manifest ?? _placeholderManifest(record),
      status: record.status,
      localPath: record.localPath,
      bytesDownloaded: downloaded,
      bytesTotal: bytesTotal,
    );
  }

  ModelManifest? _manifestFor(String modelId) {
    final manager = ref.read(modelManagerProvider);
    if (manager != null) {
      final m = manager.manifestFor(modelId);
      if (m != null) return m;
    }
    final service = ref.read(modelDownloadServiceProvider);
    return service?.manifestFor(modelId);
  }

  ModelManifest _placeholderManifest(InstalledModelRecord record) {
    return ModelManifest(
      id: record.id,
      type: record.type,
      version: record.version,
      sizeBytes: record.sizeBytes,
      downloadUrl: 'about:blank',
      sha256: '',
      artifacts: const <ModelArtifact>[],
    );
  }

  Future<bool> _verifyLocally(
      String modelId, ModelDownloadService? service) async {
    if (service == null) return false;
    final manifest = service.manifestFor(modelId);
    if (manifest == null) return false;
    final installPath =
        '${service.rootDirectory.path}/models/${manifest.id}/${manifest.version}';

    // Repository layout — every artifact is checked against its own digest.
    if (manifest.artifacts.isNotEmpty) {
      final directory = Directory(installPath);
      if (!directory.existsSync()) return false;
      for (final artifact in manifest.artifacts) {
        final artifactFile = File('$installPath/${artifact.relativePath}');
        if (!artifactFile.existsSync()) return false;
        if (artifact.sizeBytes > 0 &&
            artifactFile.lengthSync() != artifact.sizeBytes) {
          return false;
        }
        // This used to compare file length only, so an artifact that was
        // truncated to the right length or bit-flipped still reported as
        // 已校验通过 and `ModelDownloadStatus.corrupted` was unreachable —
        // the corruption then surfaced as an opaque native load failure.
        if (_isRealDigest(artifact.sha256) &&
            await _sha256OfFile(artifactFile.path) != artifact.sha256) {
          return false;
        }
      }
      return true;
    }

    // Single-file layout.
    final file = File(installPath);
    if (!file.existsSync()) return false;
    if (manifest.sizeBytes > 0 && file.lengthSync() != manifest.sizeBytes) {
      return false;
    }
    if (_isRealDigest(manifest.sha256)) {
      return await _sha256OfFile(file.path) == manifest.sha256;
    }
    // Placeholder digest: there is nothing to compare against, so accept the
    // size check rather than reporting a verification that never happened.
    return true;
  }

  static bool _isRealDigest(String value) =>
      value.isNotEmpty && value != 'PLACEHOLDER_SHA256';

  Future<String> _sha256OfFile(String path) async {
    final digest =
        await sha256.bind(File(path).openRead().cast<List<int>>()).first;
    return digest.toString();
  }
}
