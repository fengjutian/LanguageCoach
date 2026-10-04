import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/app_settings.dart';
import '../chat/application/speech_session_controller.dart';
import '../chat/application/tts_controller.dart';
import '../settings/application/settings_controller.dart';
import 'application/practice_controller.dart';
import 'data/practice_repository.dart';
import 'domain/pronunciation_score.dart';

enum RepeatStep { ready, playing, recording, scoring, result }

class RepeatPracticePage extends ConsumerStatefulWidget {
  const RepeatPracticePage({super.key});

  @override
  ConsumerState<RepeatPracticePage> createState() => _RepeatPracticePageState();
}

class _RepeatPracticePageState extends ConsumerState<RepeatPracticePage> {
  static const _samples = <CoachLanguage, List<String>>{
    CoachLanguage.english: [
      'Could you say that one more time?',
      'I would like to book a table for two.',
      'The weather is lovely today.',
    ],
    CoachLanguage.japanese: ['もう一度言っていただけますか。', '駅はどこですか。'],
    CoachLanguage.french: ['Pourriez-vous répéter, s’il vous plaît ?', 'Je voudrais un café.'],
    CoachLanguage.korean: ['다시 한 번 말씀해 주세요.', '오늘 날씨가 정말 좋아요.'],
    CoachLanguage.spanish: ['¿Podría repetirlo, por favor?', 'Quisiera reservar una mesa.'],
    CoachLanguage.german: ['Könnten Sie das bitte wiederholen?', 'Ich möchte einen Tisch reservieren.'],
    CoachLanguage.italian: ['Potrebbe ripeterlo, per favore?', 'Vorrei prenotare un tavolo.'],
    CoachLanguage.chinese: ['请问您可以再说一遍吗？', '今天天气真不错。'],
    CoachLanguage.russian: ['Повторите, пожалуйста.', 'Я хотел бы заказать столик.'],
    CoachLanguage.portuguese: ['Pode repetir, por favor?', 'Gostaria de reservar uma mesa.'],
  };

  RepeatStep _step = RepeatStep.ready;
  int _sampleIndex = 0;
  String _transcript = '';
  PronunciationScore? _score;
  DateTime? _recordingStarted;

  String _sentence(CoachLanguage language) {
    final values = _samples[language] ?? _samples[CoachLanguage.english]!;
    return values[_sampleIndex % values.length];
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsControllerProvider);
    final speech = ref.watch(speechSessionControllerProvider);
    final sentence = _sentence(settings.preferredLanguage);

    ref.listen(speechSessionControllerProvider, (previous, next) {
      if (_step == RepeatStep.recording &&
          !next.listening &&
          next.partialText.trim().isNotEmpty) {
        _finishAttempt(next.partialText.trim(), sentence, settings.preferredLanguage);
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('跟读练习'),
        actions: [
          IconButton(
            tooltip: '换一句',
            onPressed: _step == RepeatStep.recording ? null : _nextSentence,
            icon: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StepIndicator(step: _step),
          const SizedBox(height: 28),
          Text('请听原句，然后完整跟读',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Text(
                sentence,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      height: 1.45,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _step == RepeatStep.recording ? null : () => _play(sentence),
            icon: Icon(_step == RepeatStep.playing
                ? Icons.graphic_eq_rounded
                : Icons.volume_up_rounded),
            label: Text(_step == RepeatStep.playing ? '正在播放原句' : '1. 播放原句'),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _step == RepeatStep.scoring ? null : _toggleRecording,
            icon: Icon(speech.listening ? Icons.stop_rounded : Icons.mic_rounded),
            label: Text(speech.listening ? '停止并评分' : '2. 开始跟读'),
          ),
          if (speech.partialText.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('识别中：${speech.partialText}', textAlign: TextAlign.center),
          ],
          if (_step == RepeatStep.scoring) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
          if (_score != null) ...[
            const SizedBox(height: 28),
            _ScoreResult(score: _score!, transcript: _transcript),
          ],
          const SizedBox(height: 18),
          Text(
            '当前为本地近似评分：根据语音识别文本对齐估算。接入音素级评测引擎后可直接替换评分器。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _play(String sentence) async {
    setState(() => _step = RepeatStep.playing);
    await ref.read(ttsControllerProvider.notifier).playSingleSentence(
          conversationId: 'practice',
          messageId: 'repeat-${sentence.hashCode}',
          sentenceId: 'reference-${sentence.hashCode}',
          text: sentence,
          languageCode: ref.read(settingsControllerProvider).preferredLanguage.code,
        );
    if (mounted && _step == RepeatStep.playing) {
      setState(() => _step = RepeatStep.ready);
    }
  }

  Future<void> _toggleRecording() async {
    final controller = ref.read(speechSessionControllerProvider.notifier);
    final speech = ref.read(speechSessionControllerProvider);
    if (speech.listening) {
      await controller.stop();
      final text = ref.read(speechSessionControllerProvider).partialText.trim();
      if (text.isNotEmpty) {
        await _finishAttempt(
          text,
          _sentence(ref.read(settingsControllerProvider).preferredLanguage),
          ref.read(settingsControllerProvider).preferredLanguage,
        );
      }
      return;
    }
    _score = null;
    _transcript = '';
    _recordingStarted = DateTime.now();
    setState(() => _step = RepeatStep.recording);
    try {
      await controller.start();
    } catch (_) {
      if (mounted) {
        setState(() => _step = RepeatStep.ready);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法启动麦克风，请检查录音权限或语音模型。')),
        );
      }
    }
  }

  Future<void> _finishAttempt(
    String transcript,
    String reference,
    CoachLanguage language,
  ) async {
    if (_step == RepeatStep.scoring || _step == RepeatStep.result) return;
    setState(() => _step = RepeatStep.scoring);
    final duration = DateTime.now().difference(_recordingStarted ?? DateTime.now());
    final score = await ref.read(pronunciationScorerProvider).score(
          reference: reference,
          transcript: transcript,
          duration: duration,
        );
    await ref.read(practiceAttemptsProvider.notifier).add(
          newPracticeAttempt(
            language: language.code,
            referenceText: reference,
            transcript: transcript,
            score: score,
            duration: duration,
          ),
        );
    if (!mounted) return;
    setState(() {
      _transcript = transcript;
      _score = score;
      _step = RepeatStep.result;
    });
  }

  void _nextSentence() {
    setState(() {
      _sampleIndex++;
      _step = RepeatStep.ready;
      _score = null;
      _transcript = '';
    });
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.step});
  final RepeatStep step;

  @override
  Widget build(BuildContext context) {
    final active = switch (step) {
      RepeatStep.ready || RepeatStep.playing => 0,
      RepeatStep.recording => 1,
      RepeatStep.scoring || RepeatStep.result => 2,
    };
    return Row(
      children: ['播放', '录音', '评分'].asMap().entries.map((entry) {
        final selected = entry.key <= active;
        return Expanded(
          child: Column(
            children: [
              CircleAvatar(
                radius: 15,
                backgroundColor: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text('${entry.key + 1}',
                    style: TextStyle(color: selected ? Colors.white : null)),
              ),
              const SizedBox(height: 5),
              Text(entry.value),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _ScoreResult extends StatelessWidget {
  const _ScoreResult({required this.score, required this.transcript});
  final PronunciationScore score;
  final String transcript;

  @override
  Widget build(BuildContext context) {
    final items = <(String, int)>[
      ('音素', score.phoneme),
      ('准确度', score.accuracy),
      ('流利度', score.fluency),
      ('完整度', score.completeness),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('综合得分 ${score.overall}',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    )),
            const SizedBox(height: 16),
            ...items.map((item) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(children: [
                    SizedBox(width: 58, child: Text(item.$1)),
                    Expanded(child: LinearProgressIndicator(value: item.$2 / 100)),
                    const SizedBox(width: 10),
                    SizedBox(width: 28, child: Text('${item.$2}')),
                  ]),
                )),
            const Divider(height: 26),
            Text('识别结果：$transcript'),
            const SizedBox(height: 10),
            ...score.feedback.map((text) => Text('• $text')),
          ],
        ),
      ),
    );
  }
}
