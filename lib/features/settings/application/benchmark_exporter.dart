import 'dart:convert';

import 'tts_benchmark_controller.dart';

/// Pure formatter for benchmark records. Two serialisers land here so we
/// don't pile up ad-hoc string assembly at the call sites:
///   * `renderCsv`  — wide-format CSV (one row per record)
///   * `renderJson` — a JSON envelope that also carries the latest snapshot
///
/// The CSV header is fixed so downstream scripts (Excel / pandas /
/// `awk`) can ingest the file without needing a custom parser.
class BenchmarkExporter {
  const BenchmarkExporter();

  static const _csvColumns = <String>[
    'started_at',
    'label',
    'duration_ms',
    'model_id',
    'peak_rss_kb',
    'current_rss_kb',
    'thread_count',
    'error',
  ];

  String renderCsv(List<BenchmarkRecord> records) {
    final buffer = StringBuffer()..writeln(_csvColumns.join(','));
    for (final r in records) {
      buffer.writeln([
        _csvField(_iso(r.startedAt)),
        _csvField(r.label),
        r.durationMs.toString(),
        _csvField(r.modelId ?? ''),
        r.peakRssKb?.toString() ?? '',
        r.currentRssKb?.toString() ?? '',
        r.threadCount?.toString() ?? '',
        _csvField(r.error ?? ''),
      ].join(','));
    }
    return buffer.toString();
  }

  /// Newest-first JSON envelope. Includes the latest [BenchmarkSnapshot]
  /// so a single export carries enough context to compare runs.
  String renderJson({
    required List<BenchmarkRecord> records,
    BenchmarkSnapshot? snapshot,
  }) {
    final payload = <String, Object?>{
      'exportedAt': DateTime.now().toIso8601String(),
      'recordCount': records.length,
      'records': records.map(_recordToJson).toList(growable: false),
      if (snapshot != null)
        'snapshot': <String, Object?>{
          'capturedAt': snapshot.capturedAt.toIso8601String(),
          'values': snapshot.values,
        },
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Map<String, Object?> _recordToJson(BenchmarkRecord r) {
    return <String, Object?>{
      'startedAt': r.startedAt.toIso8601String(),
      'label': r.label,
      'durationMs': r.durationMs,
      'modelId': r.modelId,
      'peakRssKb': r.peakRssKb,
      'currentRssKb': r.currentRssKb,
      'threadCount': r.threadCount,
      'error': r.error,
      'hasError': r.hasError,
    };
  }

  String suggestFilename({required BenchmarkFormat format, DateTime? now}) {
    final stamp = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final base =
        'benchmark_${stamp.year}${two(stamp.month)}${two(stamp.day)}'
        '_${two(stamp.hour)}${two(stamp.minute)}';
    return format == BenchmarkFormat.csv ? '$base.csv' : '$base.json';
  }

  String _iso(DateTime dt) => dt.toIso8601String();

  /// Conservative CSV escaping — wraps in double quotes when the field
  /// contains a comma, quote, or newline, and doubles any embedded
  /// quotes. Empty / null fields render as bare empty strings.
  String _csvField(String input) {
    final needsQuotes =
        input.contains(',') || input.contains('"') || input.contains('\n');
    if (!needsQuotes) return input;
    return '"${input.replaceAll('"', '""')}"';
  }
}

enum BenchmarkFormat { csv, json }

extension BenchmarkFormatX on BenchmarkFormat {
  String get mime => this == BenchmarkFormat.csv ? 'text/csv' : 'application/json';
  String get label => this == BenchmarkFormat.csv ? 'CSV' : 'JSON';
}