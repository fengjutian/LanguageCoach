import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/app_settings.dart';
import 'application/settings_controller.dart';

/// Speech-speed choices the audio pipeline will accept downstream. Kept in
/// sync with [AppSettings.allowedSpeechSpeeds] so the UI cannot suggest a
/// value the controller would later reject.
const _kSpeechSpeedStops = <double>[0.75, 0.85, 1.0, 1.15, 1.25, 1.5];

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final controller = ref.read(settingsControllerProvider.notifier);
    return CustomScrollView(
      slivers: [
        const SliverAppBar.large(title: Text('设置')),
        SliverList.list(
          children: [
            const _SectionTitle('语言'),
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('首选语言'),
              subtitle: const Text('对话中未明确指定时使用'),
              trailing: DropdownButton<CoachLanguage>(
                value: settings.preferredLanguage,
                underline: const SizedBox.shrink(),
                onChanged: (value) {
                  if (value != null) controller.setPreferredLanguage(value);
                },
                items: CoachLanguage.values
                    .map(
                      (item) => DropdownMenuItem(
                        value: item,
                        child: Text('${item.flag} ${item.label}'),
                      ),
                    )
                    .toList(),
              ),
            ),
            const _SectionTitle('AI'),
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Provider'),
              subtitle: const Text('Auto 会根据任务复杂度自动选择'),
              trailing: DropdownButton<AiProvider>(
                value: settings.provider,
                underline: const SizedBox.shrink(),
                onChanged: (value) {
                  if (value != null) controller.setProvider(value);
                },
                items: AiProvider.values
                    .map(
                      (provider) => DropdownMenuItem(
                        value: provider,
                        child: Text(switch (provider) {
                          AiProvider.auto => 'Auto',
                          AiProvider.miniMax => 'MiniMax',
                          AiProvider.deepSeek => 'DeepSeek',
                          AiProvider.localQwen => 'Local Qwen3',
                        }),
                      ),
                    )
                    .toList(),
              ),
            ),
            const _SectionTitle('语音'),
            SwitchListTile(
              title: const Text('自动播放'),
              value: settings.autoPlay,
              onChanged: controller.setAutoPlay,
            ),
            ListTile(
              title: const Text('语速'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${settings.speechSpeed.toStringAsFixed(2)}x'),
                  Slider(
                    value: settings.speechSpeed,
                    min: _kSpeechSpeedStops.first,
                    max: _kSpeechSpeedStops.last,
                    divisions: _kSpeechSpeedStops.length - 1,
                    label: '${settings.speechSpeed.toStringAsFixed(2)}x',
                    onChanged: (next) {
                      // Snap to the nearest supported stop so the slider
                      // never feeds an off-grid value into the controller.
                      final snapped = _kSpeechSpeedStops.reduce(
                        (a, b) => ((next - a).abs() < (next - b).abs()) ? a : b,
                      );
                      controller.setSpeechSpeed(snapped);
                    },
                  ),
                ],
              ),
            ),
            const _SectionTitle('会话'),
            SwitchListTile(
              title: const Text('保存聊天记录'),
              value: settings.saveHistory,
              onChanged: controller.setSaveHistory,
            ),
            const _SectionTitle('模型'),
            const ListTile(
              leading: Icon(Icons.memory),
              title: Text('Qwen3 0.6B'),
              subtitle: Text('尚未下载'),
              trailing: Icon(Icons.download_outlined),
            ),
            const ListTile(
              leading: Icon(Icons.graphic_eq),
              title: Text('Qwen3-TTS 0.6B'),
              subtitle: Text('尚未下载'),
              trailing: Icon(Icons.download_outlined),
            ),
            const ListTile(
              leading: Icon(Icons.hearing),
              title: Text('sherpa-onnx ASR'),
              subtitle: Text('尚未下载'),
              trailing: Icon(Icons.download_outlined),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Text(
          text,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );
}
