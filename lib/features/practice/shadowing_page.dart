import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audio/practice_recorder.dart';
import '../../core/audio/tts_models.dart';
import '../../core/models/app_settings.dart';
import '../chat/application/speech_session_controller.dart';
import '../chat/application/tts_controller.dart';
import '../settings/application/settings_controller.dart';

final practiceRecorderProvider = Provider<PracticeRecorder>(
  (_) => const AndroidPracticeRecorder(),
);

enum ShadowLoopMode { off, sentence, passage }

class ShadowingPage extends ConsumerStatefulWidget {
  const ShadowingPage({super.key});

  @override
  ConsumerState<ShadowingPage> createState() => _ShadowingPageState();
}

class _ShadowingPageState extends ConsumerState<ShadowingPage> {
  static const _scripts = <CoachLanguage, List<String>>{
    CoachLanguage.english: [
      'Good morning. I would like to check in, please.',
      'Of course. May I see your passport?',
      'Here you are. Is breakfast included?',
      'Yes, it is served from seven to ten on the second floor.',
    ],
    CoachLanguage.chinese: [
      '早上好，我想办理入住。',
      '当然可以，请出示您的证件。',
      '给您。请问包含早餐吗？',
      '包含，早餐在二楼供应。'
    ],
    CoachLanguage.japanese: [
      'おはようございます。チェックインをお願いします。',
      'パスポートを見せていただけますか。',
      'はい、どうぞ。朝食は含まれていますか。'
    ],
    CoachLanguage.korean: [
      '안녕하세요. 체크인하고 싶습니다.',
      '여권을 보여 주시겠어요?',
      '여기 있습니다. 조식이 포함되어 있나요?'
    ],
    CoachLanguage.french: [
      'Bonjour, je voudrais faire mon enregistrement.',
      'Bien sûr. Puis-je voir votre passeport ?',
      'Le petit-déjeuner est-il compris ?'
    ],
    CoachLanguage.spanish: [
      'Buenos días. Quisiera registrarme.',
      'Claro. ¿Puedo ver su pasaporte?',
      '¿Está incluido el desayuno?'
    ],
    CoachLanguage.german: [
      'Guten Morgen. Ich möchte einchecken.',
      'Darf ich bitte Ihren Pass sehen?',
      'Ist das Frühstück inbegriffen?'
    ],
    CoachLanguage.italian: [
      'Buongiorno. Vorrei fare il check-in.',
      'Posso vedere il suo passaporto?',
      'La colazione è inclusa?'
    ],
    CoachLanguage.russian: [
      'Доброе утро. Я хотел бы зарегистрироваться.',
      'Можно ваш паспорт?',
      'Завтрак включён?'
    ],
    CoachLanguage.portuguese: [
      'Bom dia. Gostaria de fazer o check-in.',
      'Posso ver seu passaporte?',
      'O café da manhã está incluído?'
    ],
  };

  int _activeIndex = 0;
  double _speed = 1;
  ShadowLoopMode _loopMode = ShadowLoopMode.off;
  bool _playing = false;
  bool _recording = false;
  bool _loading = false;
  String? _recordingPath;
  /// Bumped on every play/stop so an older playback loop retires itself.
  int _playGeneration = 0;
  /// Re-entrancy guard for the mic button: `_recording` is only set *after*
  /// `await recorder.start()`, so a double tap used to call `start()` twice
  /// and leave the native recorder holding the mic while the UI believed
  /// recording had stopped.
  bool _recordingBusy = false;

  List<String> _sentences(CoachLanguage language) =>
      _scripts[language] ?? _scripts[CoachLanguage.english]!;

  @override
  void dispose() {
    _playGeneration++;
    if (_recording) {
      unawaited(ref.read(practiceRecorderProvider).cancel());
    }
    // Leaving mid-recording used to leave native capture running: the chat
    // page owns the ASR session, the provider is non-autoDispose, and its
    // onDispose only detaches the event stream — nothing called `stop()`.
    // `ref` is unusable during finalization, so the notifier is captured in
    // `build` instead.
    if (_wasListening) {
      unawaited(_speech?.stop());
    }
    super.dispose();
  }

  /// Captured while the page is still alive — see [dispose].
  SpeechSessionController? _speech;
  bool _wasListening = false;

  @override
  Widget build(BuildContext context) {
    final language = ref.watch(settingsControllerProvider).preferredLanguage;
    final sentences = _sentences(language);
    final speech = ref.watch(speechSessionControllerProvider);
    _speech = ref.read(speechSessionControllerProvider.notifier);
    _wasListening = speech.listening;
    return Scaffold(
      appBar: AppBar(title: const Text('影子训练')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Text('酒店入住',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const Spacer(),
                SegmentedButton<double>(
                  segments: const [
                    ButtonSegment(value: .75, label: Text('0.75×')),
                    ButtonSegment(value: 1, label: Text('1×')),
                    ButtonSegment(value: 1.25, label: Text('1.25×')),
                  ],
                  selected: {_speed},
                  onSelectionChanged: (value) async {
                    final speed = value.first;
                    setState(() => _speed = speed);
                    await ref.read(audioPlayerServiceProvider).setSpeed(speed);
                  },
                  showSelectedIcon: false,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: sentences.length,
              itemBuilder: (context, index) {
                final active = index == _activeIndex;
                return Card(
                  color: active
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: ListTile(
                    leading: CircleAvatar(child: Text('${index + 1}')),
                    title: Text(sentences[index],
                        style: TextStyle(
                            fontWeight: active ? FontWeight.w700 : null)),
                    trailing: active && _playing
                        ? const Icon(Icons.graphic_eq_rounded)
                        : const Icon(Icons.play_arrow_rounded),
                    onTap: () {
                      setState(() => _activeIndex = index);
                      _play(fromIndex: index);
                    },
                  ),
                );
              },
            ),
          ),
          Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton.filledTonal(
                          tooltip: _loopLabel,
                          onPressed: _cycleLoop,
                          icon: Icon(_loopMode == ShadowLoopMode.sentence
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded),
                        ),
                        const SizedBox(width: 22),
                        IconButton.filled(
                          iconSize: 34,
                          tooltip: _playing ? '停止' : '播放',
                          onPressed:
                              _loading ? null : (_playing ? _stop : _play),
                          icon: _loading
                              ? const SizedBox.square(
                                  dimension: 26,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 3))
                              : Icon(_playing
                                  ? Icons.stop_rounded
                                  : Icons.play_arrow_rounded),
                        ),
                        const SizedBox(width: 22),
                        IconButton.filledTonal(
                          tooltip: _recording ? '停止录音' : '录音',
                          onPressed: _toggleRecording,
                          icon: Icon(_recording
                              ? Icons.stop_rounded
                              : Icons.mic_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('$_loopLabel · $_speed×'),
                    if (_recordingPath != null)
                      TextButton.icon(
                        onPressed: _playRecording,
                        icon: const Icon(Icons.play_circle_outline),
                        label: const Text('回放我的录音'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _loopLabel => switch (_loopMode) {
        ShadowLoopMode.off => '不循环',
        ShadowLoopMode.sentence => '单句循环',
        ShadowLoopMode.passage => '整段循环',
      };

  Future<void> _play({int? fromIndex}) async {
    if (_recording) await _toggleRecording();
    final language = ref.read(settingsControllerProvider).preferredLanguage;
    final sentences = _sentences(language);
    var index = fromIndex ?? _activeIndex;
    // A second `_play` (tapping a sentence while one is already running)
    // used to start a *second* loop on the same shared player: `_playing`
    // stayed true so the first loop never exited, both interleaved audio,
    // and whichever finished first cleared the flags while the other was
    // still playing. The token retires the older loop immediately.
    final token = ++_playGeneration;
    setState(() {
      _playing = true;
      _loading = true;
    });
    final player = ref.read(audioPlayerServiceProvider);
    await player.setSpeed(_speed);
    try {
      while (mounted && _playing && token == _playGeneration) {
        setState(() => _activeIndex = index);
        final result = await ref.read(ttsEngineProvider).synthesize(TtsRequest(
              text: sentences[index],
              language: language.code,
              speed: 1,
            ));
        if (!mounted || !_playing) break;
        setState(() => _loading = false);
        await player.load(result.audioPath);
        await player.setSpeed(_speed);
        await player.play();
        if (!mounted || !_playing) break;
        if (_loopMode == ShadowLoopMode.sentence) continue;
        if (index < sentences.length - 1) {
          index++;
        } else if (_loopMode == ShadowLoopMode.passage) {
          index = 0;
        } else {
          break;
        }
        setState(() => _loading = true);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败：$error')),
        );
      }
    } finally {
      // Only the loop that still owns the playback may reset the flags.
      if (mounted && token == _playGeneration) {
        setState(() {
          _playing = false;
          _loading = false;
        });
      }
    }
  }

  Future<void> _stop() async {
    // Retire the running loop so its `finally` becomes a no-op.
    _playGeneration++;
    if (mounted) {
      setState(() {
        _playing = false;
        _loading = false;
      });
    }
    await ref.read(audioPlayerServiceProvider).stop();
  }

  void _cycleLoop() {
    setState(() {
      _loopMode = switch (_loopMode) {
        ShadowLoopMode.off => ShadowLoopMode.sentence,
        ShadowLoopMode.sentence => ShadowLoopMode.passage,
        ShadowLoopMode.passage => ShadowLoopMode.off,
      };
    });
  }

  Future<void> _toggleRecording() async {
    if (_recordingBusy) return;
    _recordingBusy = true;
    final recorder = ref.read(practiceRecorderProvider);
    try {
      if (_recording) {
        final path = await recorder.stop();
        if (mounted) {
          setState(() {
            _recording = false;
            _recordingPath = path;
          });
        }
      } else {
        await _stop();
        await recorder.start();
        if (mounted) setState(() => _recording = true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('录音失败：$error')),
        );
      }
    } finally {
      _recordingBusy = false;
    }
  }

  Future<void> _playRecording() async {
    final path = _recordingPath;
    if (path == null) return;
    await _stop();
    final player = ref.read(audioPlayerServiceProvider);
    await player.load(path);
    await player.setSpeed(1);
    await player.play();
  }
}
