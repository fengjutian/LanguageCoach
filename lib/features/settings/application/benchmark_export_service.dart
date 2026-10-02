import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../history/application/conversation_export_service.dart';
import 'benchmark_exporter.dart';
import 'tts_benchmark_controller.dart';

/// End-to-end benchmark export pipeline. The same shape as
/// [ConversationExportService] — pure formatter ([BenchmarkExporter]) +
/// thin orchestrator + shareable file. Reuses [ShareService] so tests
/// can swap in a fake the same way the history export does.
class BenchmarkExportService {
  BenchmarkExportService({
    required BenchmarkExporter exporter,
    required ShareService share,
    Future<Directory> Function()? tempDirectoryProvider,
  })  : _exporter = exporter,
        _share = share,
        _tempDirectoryProvider = tempDirectoryProvider ?? getTemporaryDirectory;

  final BenchmarkExporter _exporter;
  final ShareService _share;
  final Future<Directory> Function() _tempDirectoryProvider;

  Future<String> export({
    required List<BenchmarkRecord> records,
    BenchmarkSnapshot? snapshot,
    required BenchmarkFormat format,
    DateTime? now,
  }) async {
    final body = format == BenchmarkFormat.csv
        ? _exporter.renderCsv(records)
        : _exporter.renderJson(records: records, snapshot: snapshot);
    final filename = _exporter.suggestFilename(format: format, now: now);
    final dir = await _tempDirectoryProvider();
    final file = File(p.join(dir.path, filename));
    await file.writeAsString(body);

    await _share.shareFile(
      path: file.path,
      subject: 'TTS benchmark (${format.label})',
      text: '${records.length} record(s) captured.',
    );
    return file.path;
  }
}
