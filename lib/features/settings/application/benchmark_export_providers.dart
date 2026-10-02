import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../history/application/conversation_export_providers.dart';
import 'benchmark_export_service.dart';
import 'benchmark_exporter.dart';
import 'tts_benchmark_controller.dart';

final benchmarkExportServiceProvider = Provider<BenchmarkExportService>((ref) {
  return BenchmarkExportService(
    exporter: const BenchmarkExporter(),
    share: ref.read(shareServiceProvider),
  );
});

/// Fire-and-await export. The caller passes the records + snapshot from
/// [ttsBenchmarkControllerProvider]; the service writes the file and
/// triggers the system share sheet.
final exportBenchmarkProvider = FutureProvider.autoDispose
    .family<String, BenchmarkFormat>((ref, format) async {
  final benchmark = ref.read(ttsBenchmarkControllerProvider);
  return ref.read(benchmarkExportServiceProvider).export(
        records: benchmark.records,
        snapshot: benchmark.snapshot,
        format: format,
      );
});
