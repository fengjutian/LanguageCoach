import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/features/settings/application/benchmark_export_service.dart';
import 'package:language_coach/features/settings/application/benchmark_exporter.dart';
import 'package:language_coach/features/settings/application/tts_benchmark_controller.dart';
import 'package:language_coach/features/history/application/conversation_export_service.dart';

void main() {
  group('BenchmarkExporter', () {
    const exporter = BenchmarkExporter();

    test('CSV header has all columns and rows escape commas + quotes', () {
      final csv = exporter.renderCsv([
        BenchmarkRecord(
          label: 'load qwen3-tts-0.6B',
          startedAt: DateTime(2026, 10, 2, 14, 0),
          durationMs: 320,
          modelId: 'qwen3-tts-0.6B',
          peakRssKb: 4096,
          currentRssKb: 3800,
          threadCount: 8,
        ),
        BenchmarkRecord(
          label: 'synthesize, with comma',
          startedAt: DateTime(2026, 10, 2, 14, 1),
          durationMs: 240,
          error: 'boom "with quotes"',
        ),
      ]);

      final lines = csv.trim().split('\n');
      expect(lines.first,
          'started_at,label,duration_ms,model_id,peak_rss_kb,current_rss_kb,thread_count,error');
      expect(lines[1], contains('load qwen3-tts-0.6B'));
      expect(lines[2], contains('"synthesize, with comma"'));
      expect(lines[2], contains('"boom ""with quotes"""'));
    });

    test('JSON envelope embeds records and the snapshot', () {
      final snapshot = BenchmarkSnapshot(
        capturedAt: DateTime(2026, 10, 2, 14, 0),
        values: const {'isLoaded': true, 'peakRssKb': 9000},
      );
      final json = exporter.renderJson(
        records: [
          BenchmarkRecord(
            label: 'warmup',
            startedAt: DateTime(2026, 10, 2, 14, 0),
            durationMs: 90,
          ),
        ],
        snapshot: snapshot,
      );
      final decoded = jsonDecode(json) as Map<String, Object?>;
      expect(decoded['recordCount'], 1);
      final records = decoded['records'] as List;
      expect(records.single['label'], 'warmup');
      final snap = decoded['snapshot'] as Map<String, Object?>;
      expect(snap['values'], {'isLoaded': true, 'peakRssKb': 9000});
    });

    test('suggestFilename picks the matching extension', () {
      expect(
        exporter.suggestFilename(
          format: BenchmarkFormat.csv,
          now: DateTime(2026, 10, 2, 9, 5),
        ),
        'benchmark_20261002_0905.csv',
      );
      expect(
        exporter.suggestFilename(
          format: BenchmarkFormat.json,
          now: DateTime(2026, 10, 2, 9, 5),
        ),
        'benchmark_20261002_0905.json',
      );
    });
  });

  group('BenchmarkExportService', () {
    late _FakeShare share;
    late RecordingDirectory dir;
    late BenchmarkExportService service;

    setUp(() {
      share = _FakeShare();
      dir = RecordingDirectory();
      service = BenchmarkExportService(
        exporter: const BenchmarkExporter(),
        share: share,
        tempDirectoryProvider: () async => dir.delegate,
      );
    });

    test('CSV export writes a file and asks the share service to surface it',
        () async {
      final path = await service.export(
        records: [
          BenchmarkRecord(
            label: 'synth (12 chars)',
            startedAt: DateTime(2026, 10, 2, 14, 0),
            durationMs: 240,
          ),
        ],
        snapshot: null,
        format: BenchmarkFormat.csv,
      );
      expect(share.lastPath, path);
      expect(share.lastSubject, contains('CSV'));
      final body = await File(path).readAsString();
      expect(
          body.split('\n').first, startsWith('started_at,label,duration_ms'));
    });

    test('JSON export writes a parseable envelope', () async {
      final path = await service.export(
        records: [
          BenchmarkRecord(
            label: 'warmup',
            startedAt: DateTime(2026, 10, 2, 14, 0),
            durationMs: 90,
          ),
        ],
        snapshot: null,
        format: BenchmarkFormat.json,
      );
      final decoded =
          jsonDecode(await File(path).readAsString()) as Map<String, Object?>;
      expect(decoded['recordCount'], 1);
    });
  });
}

class _FakeShare implements ShareService {
  String? lastPath;
  String? lastSubject;
  String? lastText;

  @override
  Future<void> shareFile({
    required String path,
    String? text,
    String? subject,
  }) async {
    lastPath = path;
    lastSubject = subject;
    lastText = text;
  }
}

class RecordingDirectory {
  RecordingDirectory()
      : delegate = Directory.systemTemp.createTempSync('bench_export_test_');
  final Directory delegate;
}
