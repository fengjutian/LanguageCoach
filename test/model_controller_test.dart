import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/model_download_service.dart';
import 'package:language_coach/core/audio/model_manager.dart';
import 'package:language_coach/core/audio/model_manifest.dart';
import 'package:language_coach/features/settings/application/model_controller.dart';

void _ignoreFuture(Future<void> _) {}

/// Stub service: every [download] immediately writes a placeholder file
/// and emits Started + Installed so the UI sees a happy transition.
class _StubService extends ModelDownloadService {
  _StubService({
    required super.rootDirectory,
    required super.events,
  });

  int downloads = 0;

  @override
  Future<String?> download(ModelManifest manifest) async {
    downloads++;
    final installPath =
        '${rootDirectory.path}/${manifest.id}/${manifest.version}';
    await Directory(installPath).parent.create(recursive: true);
    await File(installPath).writeAsBytes(const <int>[1, 2, 3]);
    events.add(ModelDownloadStarted(manifest.id, manifest.sizeBytes));
    events.add(ModelInstalled(manifest.id, installPath));
    return installPath;
  }

  @override
  ModelManifest? manifestFor(String modelId) {
    if (modelId == 'qwen3-tts-0.6B') return qwen3Tts06B;
    return null;
  }
}

void main() {
  test('download delegates to the service and emits events', () async {
    final tmp = await Directory.systemTemp.createTemp('model_ctrl_test_');
    final events = StreamController<ModelEvent>.broadcast();
    final service = _StubService(
      rootDirectory: Directory('${tmp.path}/models'),
      events: events,
    );
    final container = ProviderContainer(overrides: [
      modelDownloadServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);

    final received = <ModelEvent>[];
    final sub = events.stream.listen(received.add);
    addTearDown(() => _ignoreFuture(sub.cancel()));

    final controller = container.read(modelControllerProvider.notifier);
    await controller.download('qwen3-tts-0.6B');
    // Broadcast stream listeners fire on a microtask — let the queue drain
    // before we assert on the captured events.
    await Future<void>.delayed(Duration.zero);
    expect(service.downloads, 1);
    expect(received.whereType<ModelDownloadStarted>().length, 1);
    expect(received.whereType<ModelInstalled>().length, 1);
    await tmp.delete(recursive: true);
  });

  test('download with unknown id is a no-op', () async {
    final tmp = await Directory.systemTemp.createTemp('model_ctrl_unknown_');
    final events = StreamController<ModelEvent>.broadcast();
    final service = _StubService(
      rootDirectory: Directory('${tmp.path}/models'),
      events: events,
    );
    final container = ProviderContainer(overrides: [
      modelDownloadServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(container.dispose);

    final controller = container.read(modelControllerProvider.notifier);
    await controller.download('does-not-exist');
    expect(service.downloads, 0);
    await tmp.delete(recursive: true);
  });
}