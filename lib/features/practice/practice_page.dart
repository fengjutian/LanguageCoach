import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/app_settings.dart';
import '../settings/application/settings_controller.dart';

enum PracticeMode { repeat, shadowing, correction }

class PracticePage extends ConsumerWidget {
  const PracticePage({super.key, required this.onStart});

  final ValueChanged<String> onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(settingsControllerProvider).preferredLanguage;
    return Scaffold(
      appBar: AppBar(title: const Text('练习')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text(
            '选择训练方式',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 6),
          Text('当前目标语言：${_languageName(language)}'),
          const SizedBox(height: 20),
          _PracticeCard(
            icon: Icons.record_voice_over_outlined,
            title: '跟读练习',
            description: '让教练生成短句，逐句播放后跟读，并获得表达建议。',
            actionLabel: '开始跟读',
            onTap: () => onStart(_prompt(PracticeMode.repeat, language)),
          ),
          _PracticeCard(
            icon: Icons.graphic_eq,
            title: '影子训练',
            description: '使用连贯的生活场景材料，紧跟音频节奏进行复述。',
            actionLabel: '开始影子训练',
            onTap: () => onStart(_prompt(PracticeMode.shadowing, language)),
          ),
          _PracticeCard(
            icon: Icons.fact_check_outlined,
            title: '纠错练习',
            description: '提交自己的句子，获取纠错、原因和更自然的表达。',
            actionLabel: '开始纠错',
            onTap: () => onStart(_prompt(PracticeMode.correction, language)),
          ),
        ],
      ),
    );
  }
}

class _PracticeCard extends StatelessWidget {
  const _PracticeCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.primary, size: 30),
            const SizedBox(height: 12),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(description),
            const SizedBox(height: 14),
            FilledButton.tonal(
              onPressed: onTap,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}

String _prompt(PracticeMode mode, CoachLanguage language) {
  final target = _languageName(language);
  return switch (mode) {
    PracticeMode.repeat =>
      '请为我生成 3 句适合跟读的$target日常表达。请从简单到稍难排列，逐句解释关键词，并提醒我播放后开口跟读。',
    PracticeMode.shadowing =>
      '请为我生成一段约 30 秒的$target生活场景影子训练材料。先给完整文本，再按句拆分，并标出停顿和重音建议。',
    PracticeMode.correction =>
      '我要进行$target纠错练习。请先让我输入一句话，然后指出错误、解释原因，并给出自然表达和一个同类练习题。',
  };
}

String _languageName(CoachLanguage language) => switch (language) {
      CoachLanguage.english => '英语',
      CoachLanguage.japanese => '日语',
      CoachLanguage.french => '法语',
      CoachLanguage.korean => '韩语',
      CoachLanguage.spanish => '西班牙语',
      CoachLanguage.german => '德语',
      CoachLanguage.italian => '意大利语',
      CoachLanguage.chinese => '中文',
      CoachLanguage.russian => '俄语',
      CoachLanguage.portuguese => '葡萄牙语',
    };
