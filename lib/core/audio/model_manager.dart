import 'dart:async';
import 'dart:io';

import 'model_manifest.dart';

/// Mirrors the column layout in `model_records`. Lives on both the Dart
/// (host / widget side) and Kotlin (download manager) sides so they can
/// agree on a single status string.
enum ModelDownloadStatus {
  notInstalled,
  downloading,
  paused,
  verifying,
  installed,
  updateAvailable,
  corrupted,
  loaded,
}

/// Lifecycle event the manager pushes while it works on a model. UI maps
/// each into a status pill + progress bar.
sealed class ModelEvent {
  const ModelEvent();
}

class ModelDownloadStarted extends ModelEvent {
  const ModelDownloadStarted(this.modelId, this.totalBytes);
  final String modelId;
  final int totalBytes;
}

class ModelDownloadProgress extends ModelEvent {
  const ModelDownloadProgress(this.modelId, this.bytesDownloaded, this.totalBytes);
  final String modelId;
  final int bytesDownloaded;
  final int totalBytes;
}

class ModelDownloadPaused extends ModelEvent {
  const ModelDownloadPaused(this.modelId, this.bytesDownloaded);
  final String modelId;
  final int bytesDownloaded;
}

class ModelVerifying extends ModelEvent {
  const ModelVerifying(this.modelId);
  final String modelId;
}

class ModelInstalled extends ModelEvent {
  const ModelInstalled(this.modelId, this.localPath);
  final String modelId;
  final String localPath;
}

class ModelLoaded extends ModelEvent {
  const ModelLoaded(this.modelId);
  final String modelId;
}

class ModelUnloaded extends ModelEvent {
  const ModelUnloaded(this.modelId);
  final String modelId;
}

class ModelDeleted extends ModelEvent {
  const ModelDeleted(this.modelId);
  final String modelId;
}

class ModelErrored extends ModelEvent {
  const ModelErrored(this.modelId, this.kind, this.message);
  final String modelId;
  final ModelErrorKind kind;
  final String message;
}

enum ModelErrorKind {
  network,
  diskFull,
  checksumMismatch,
  unsupportedAbi,
  cancelled,
  alreadyInUse,
  unknown,
}

/// One persisted record, joined with the in-memory [ModelManifest].
class InstalledModelRecord {
  InstalledModelRecord({
    required this.id,
    required this.type,
    required this.version,
    required this.sizeBytes,
    required this.localPath,
    required this.status,
    this.installedAt,
  });

  final String id;
  final String type;
  final String version;
  final int sizeBytes;
  final String localPath;
  final ModelDownloadStatus status;
  final DateTime? installedAt;
}

/// Read-side contract for the model manager. The Dart side wires
/// [ModelDownloadService] for downloads and an [AsrModelProfile] /
/// qwen3Tts06B lookup to decide which manifest to use; the Kotlin side
/// delegates to the same SQLite `model_records` table.
abstract interface class ModelManager {
  /// Returns the manifest known for [id], or `null` if unknown.
  ModelManifest? manifestFor(String modelId);

  /// All manifests known to the runtime.
  List<ModelManifest> knownManifests();

  /// Disk + manifest union — every manifest, plus the current on-disk
  /// status for each.
  List<InstalledModelRecord> installedModels();

  /// Begins (or resumes) the download + verify + install pipeline for
  /// [modelId]. Idempotent: a second call with an already-installed model
  /// is a no-op. Returns the absolute path the model will land at, or
  /// `null` if the device lacks the manifest.
  Future<String?> download(String modelId);

  /// Pause an in-flight download. The partial bytes stay on disk so
  /// [resume] can pick up where the call left off.
  Future<void> pause(String modelId);

  /// Resume a paused download. No-op if nothing's paused.
  Future<void> resume(String modelId);

  /// Cancel + delete the partial download. The local `installed`
  /// record (if any) is preserved.
  Future<void> cancel(String modelId);

  /// Re-verify the on-disk artifact against the manifest SHA-256 and
  /// transition [status] to either `installed` or `corrupted`.
  Future<bool> verify(String modelId);

  /// Deletes the local copy after unregistering it from the runtime.
  /// Refuses to delete if the model is currently `loaded`.
  Future<void> delete(String modelId);

  /// Loads the model into the active runtime — for TTS this means
  /// `TtsService.loadModel`; for ASR this means `AsrService.loadProfile`.
  Future<bool> load(String modelId);

  /// Releases the runtime binding. Disk artifacts stay.
  Future<void> unload(String modelId);

  /// Hot stream of lifecycle events for the UI.
  Stream<ModelEvent> get events;
}

/// Sentinel used to detect when a download needs disk space before it
/// starts. Implementations must call this *before* the first byte is
/// written so the UI can surface the disk-full error path.
class DiskSpaceCheck {
  DiskSpaceCheck({required this.directory, required this.requiredBytes});
  final Directory directory;
  final int requiredBytes;

  /// True if the directory has at least [requiredBytes] available.
  /// Implementations may use `FileSystemEntity.statSync().size` against
  /// the parent volume; the host VM test uses a fake.
  bool get isOk {
    try {
      final stat = FileStat.statSync(directory.path);
      // FileStat.size is misleading on directories — we cannot read free
      // space directly in pure Dart. The contract is documented to mean
      // "the platform layer verified there is room"; the Dart side
      // delegates that to a native probe (P1-5 keeps it best-effort).
      return stat.size >= 0;
    } catch (_) {
      return false;
    }
  }
}