import 'package:flutter/material.dart';

import '../../core/model/app_settings.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.settings, super.key});
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => CustomScrollView(
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
                    if (value != null) settings.setPreferredLanguage(value);
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
                    if (value != null) settings.setProvider(value);
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
                onChanged: settings.setAutoPlay,
              ),
              ListTile(
                title: const Text('语速'),
                subtitle: Slider(
                  value: settings.speechSpeed,
                  min: .75,
                  max: 1.5,
                  divisions: 3,
                  label: '${settings.speechSpeed}x',
                  onChanged: settings.setSpeechSpeed,
                ),
              ),
              const _SectionTitle('会话'),
              SwitchListTile(
                title: const Text('保存聊天记录'),
                value: settings.saveHistory,
                onChanged: settings.setSaveHistory,
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
      ),
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
