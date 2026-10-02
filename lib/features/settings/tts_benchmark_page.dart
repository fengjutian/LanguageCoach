import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/benchmark_export_providers.dart';
import 'application/benchmark_exporter.dart';
import 'application/tts_benchmark_controller.dart';

/// Diagnostic screen that talks to the native Qwen3-TTS runtime. Lives
/// outside the chat surface — the design says no UI rewrite here, just a
/// standalone benchmark tool reachable from the settings page.
class TtsBenchmarkPage extends ConsumerStatefulWidget {
  const TtsBenchmarkPage({super.key});

  @override
  ConsumerState<TtsBenchmarkPage> createState() => _TtsBenchmarkPageState();
}

class _TtsBenchmarkPageState extends ConsumerState<TtsBenchmarkPage> {
  final _textController = TextEditingController(
    text: 'The quick brown fox jumps over the lazy dog.',
  );

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(ttsBenchmarkControllerProvider);
    final controller = ref.read(ttsBenchmarkControllerProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('TTS Benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusTile(state: state),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: state.busy ? null : controller.loadSelected,
                icon: const Icon(Icons.download),
                label: const Text('Load model'),
              ),
              OutlinedButton.icon(
                onPressed:
                    state.busy || !state.loaded ? null : controller.warmup,
                icon: const Icon(Icons.local_fire_department),
                label: const Text('Warmup'),
              ),
              OutlinedButton.icon(
                onPressed: state.busy || !state.loaded
                    ? null
                    : () => controller.synthesize(_textController.text),
                icon: const Icon(Icons.record_voice_over),
                label: const Text('Synthesize'),
              ),
              OutlinedButton.icon(
                onPressed:
                    state.busy || !state.loaded ? null : controller.cancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Cancel'),
              ),
              OutlinedButton.icon(
                onPressed:
                    state.busy || !state.loaded ? null : controller.unload,
                icon: const Icon(Icons.cleaning_services),
                label: const Text('Unload'),
              ),
              OutlinedButton.icon(
                onPressed: state.records.isEmpty
                    ? null
                    : () => _showExportMenu(context),
                icon: const Icon(Icons.ios_share),
                label: const Text('Export'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _textController,
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Test text',
            ),
          ),
          const SizedBox(height: 16),
          if (state.snapshot != null) _SnapshotCard(snapshot: state.snapshot!),
          const SizedBox(height: 12),
          Text('Records (most recent first)',
              style: Theme.of(context).textTheme.titleSmall),
          if (state.records.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No records yet — load a model to start.'),
            )
          else
            ...state.records.map((r) => _RecordTile(record: r)),
        ],
      ),
    );
  }

  Future<void> _showExportMenu(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final picked = await showModalBottomSheet<BenchmarkFormat>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('导出为 CSV'),
              onTap: () => Navigator.pop(ctx, BenchmarkFormat.csv),
            ),
            ListTile(
              leading: const Icon(Icons.data_object),
              title: const Text('导出为 JSON'),
              onTap: () => Navigator.pop(ctx, BenchmarkFormat.json),
            ),
          ],
        ),
      ),
    );
    if (!mounted || picked == null) return;
    try {
      final path =
          await ref.read(exportBenchmarkProvider(picked).future);
      messenger.showSnackBar(
        SnackBar(content: Text('已导出到 $path')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    }
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.state});
  final BenchmarkState state;

  @override
  Widget build(BuildContext context) {
    final color = state.loaded ? Colors.green : Colors.orange;
    return Card(
      child: ListTile(
        leading: Icon(
          state.loaded ? Icons.check_circle : Icons.pending,
          color: color,
        ),
        title: Text(state.modelId),
        subtitle: Text(state.loaded ? 'Loaded' : 'Not loaded'),
      ),
    );
  }
}

class _SnapshotCard extends StatelessWidget {
  const _SnapshotCard({required this.snapshot});
  final BenchmarkSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Runtime snapshot',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final entry in snapshot.values.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text('${entry.key}:',
                          style: const TextStyle(color: Colors.black54)),
                    ),
                    Expanded(child: Text('${entry.value}')),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RecordTile extends StatelessWidget {
  const _RecordTile({required this.record});
  final BenchmarkRecord record;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
          record.hasError ? Icons.error_outline : Icons.timer_outlined,
          color: record.hasError ? Theme.of(context).colorScheme.error : null),
      title: Text(record.label),
      subtitle:
          Text('started ${_hhmm(record.startedAt)} • ${record.durationMs} ms'),
      trailing: record.hasError
          ? const Icon(Icons.warning_amber)
          : Text('${record.durationMs} ms'),
    );
  }

  String _hhmm(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
