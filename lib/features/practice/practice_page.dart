import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/app_settings.dart';
import '../settings/application/settings_controller.dart';
import 'application/practice_controller.dart';
import 'repeat_practice_page.dart';
import 'roleplay_page.dart';
import 'shadowing_page.dart';

enum PracticeMode { repeat, shadowing, correction }

class PracticePage extends ConsumerWidget {
  const PracticePage({super.key, required this.onStart});
  final ValueChanged<String> onStart;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final language = ref.watch(settingsControllerProvider).preferredLanguage;
    final attempts = ref.watch(practiceAttemptsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('练习')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('选择训练方式',
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('当前目标语言：${_languageName(language)}'),
          const SizedBox(height: 16),
          attempts.when(
            data: (items) => Column(
              children: [
                _PracticeSummary(
                  count: items.length,
                  average: items.isEmpty
                      ? null
                      : items
                              .map((e) => e.score.overall)
                              .reduce((a, b) => a + b) ~/
                          items.length,
                  latest: items.isEmpty ? null : items.first.score.overall,
                ),
                if (items.isNotEmpty)
                  ExpansionTile(
                    title: const Text('最近练习'),
                    subtitle: const Text('查看成绩与复习原句'),
                    children: items.take(5).map((item) {
                      return ListTile(
                        leading:
                            CircleAvatar(child: Text('${item.score.overall}')),
                        title: Text(item.referenceText,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${item.createdAt.month}-${item.createdAt.day}  '
                          '准确 ${item.score.accuracy} · 流利 ${item.score.fluency}',
                        ),
                      );
                    }).toList(),
                  ),
              ],
            ),
            loading: () => const LinearProgressIndicator(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          const SizedBox(height: 18),
          _PracticeCard(
            icon: Icons.record_voice_over_outlined,
            title: '跟读练习',
            description: '播放原句、录音跟读、自动对比，并获得音素、准确度、流利度和完整度评分。',
            actionLabel: '开始跟读',
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const RepeatPracticePage())),
          ),
          _PracticeCard(
            icon: Icons.graphic_eq,
            title: '影子训练',
            description: '使用连贯的生活场景材料，紧跟音频节奏进行复述。',
            actionLabel: '开始影子训练',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const ShadowingPage()),
            ),
          ),
          _PracticeCard(
            icon: Icons.fact_check_outlined,
            title: '纠错练习',
            description: '提交自己的句子，获取纠错、原因和更自然的表达。',
            actionLabel: '开始纠错',
            onTap: () => onStart(_prompt(PracticeMode.correction, language)),
          ),
          _PracticeCard(
            icon: Icons.theater_comedy_outlined,
            title: 'Roleplay 情景对话',
            description: '选择角色、场景和任务目标，在独立对话中完成挑战并获取结束总结。',
            actionLabel: '选择场景',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const RoleplayPage()),
            ),
          ),
        ],
      ),
    );
  }
}

class _PracticeSummary extends StatelessWidget {
  const _PracticeSummary({required this.count, this.average, this.latest});
  final int count;
  final int? average;
  final int? latest;
  @override
  Widget build(BuildContext context) => Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _Metric(label: '练习次数', value: '$count'),
            _Metric(label: '平均分', value: average?.toString() ?? '--'),
            _Metric(label: '最近成绩', value: latest?.toString() ?? '--'),
          ]),
        ),
      );
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Column(children: [
        Text(value,
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ]);
}

class _PracticeCard extends StatelessWidget {
  const _PracticeCard(
      {required this.icon,
      required this.title,
      required this.description,
      required this.actionLabel,
      required this.onTap});
  final IconData icon;
  final String title;
  final String description;
  final String actionLabel;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary, size: 30),
            const SizedBox(height: 12),
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(description),
            const SizedBox(height: 14),
            FilledButton.tonal(onPressed: onTap, child: Text(actionLabel)),
          ]),
        ),
      );
}

String _prompt(PracticeMode mode, CoachLanguage language) {
  final target = _languageName(language);
  return switch (mode) {
    PracticeMode.repeat => '请为我生成 3 句适合跟读的$target日常表达。',
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
