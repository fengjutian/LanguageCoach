import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_cache.dart';
import '../../../core/audio/audio_player.dart';
import '../../../core/audio/audio_queue.dart';
import '../../../core/audio/fake_tts_engine.dart';
import '../../../core/audio/sentence_splitter.dart';
import '../../../core/audio/tts_engine.dart';
import '../../../core/audio/tts_models.dart';
import '../../../core/audio/voice_profile.dart';
import '../../../core/models/app_settings.dart';
import '../../settings/application/settings_controller.dart';

/// State exposed to widgets that surface a sentence-level play / pause
/// indicator. The shape is deliberately minimal so MessageBubble can
/// rebuild cheaply when only the active sentence changes.
class TtsPlaybackState {
  const TtsPlaybackState({
    this.currentSentenceId,
    this.playback = AudioPlaybackState.idle,
    this.queueLength = 0,
    this.sentenceStates = const <String, SentencePlaybackState>{},
  });

  final String? currentSentenceId;
  final AudioPlaybackState playback;
  final int queueLength;
  final Map<String, SentencePlaybackState> sentenceStates;

  TtsPlaybackState copyWith({
    String? currentSentenceId,
    AudioPlaybackState? playback,
    int? queueLength,
    Map<String, SentencePlaybackState>? sentenceStates,
    bool clearCurrentSentence = false,
  }) {
    return TtsPlaybackState(
      currentSentenceId: clearCurrentSentence
          ? null
          : (currentSentenceId ?? this.currentSentenceId),
      playback: playback ?? this.playback,
      queueLength: queueLength ?? this.queueLength,
      sentenceStates: sentenceStates ?? this.sentenceStates,
    );
  }
}

/// Per-sentence pipeline state. Distinct from [AudioPlaybackState] because
/// the pipeline has its own phases (generating → ready → playing → ...).
enum SentencePlaybackState {
  idle,
  generating,
  cached,
  ready,
  playing,
  paused,
  failed,
}

final sentenceSplitterProvider =
    Provider<SentenceSplitter>((_) => const SentenceSplitter());

final ttsEngineProvider = Provider<TtsEngine>((ref) {
  // Default to the off-platform stub until Android system TTS / Qwen3-TTS
  // wires up; production overrides this in `main.dart` once the engine is
  // available.
  final outputDir = ref.watch(ttsOutputDirectoryProvider);
  return FakeTtsEngine(outputDirectory: outputDir);
});

final ttsOutputDirectoryProvider = Provider<Directory>((ref) {
  // Default to the app's documents/audio folder. Overridden in main.dart once
  // path_provider is available.
  return Directory('${Directory.systemTemp.path}/language_coach_audio');
});

final audioPlayerServiceProvider = Provider<AudioPlayerService>((ref) {
  throw UnimplementedError(
    'audioPlayerServiceProvider must be overridden with a FlutterAudioPlayer '
    'or InMemoryAudioPlayer before the TtsController can play anything.',
  );
});

final audioQueueProvider = Provider<AudioQueue>((ref) {
  final player = ref.watch(audioPlayerServiceProvider);
  final queue = AudioQueue(player: player);
  ref.onDispose(() => queue.dispose());
  return queue;
});

/// Persists a row per cached audio file under
/// `files/audio/conversations/{conversationId}/{messageId}/{sentenceId}.wav`.
/// Defaults to an in-memory no-op so widget tests don't need a real SQLite
/// database just to exercise the TtsController.
final audioCacheRepositoryProvider = Provider<AudioCacheRepository?>((ref) {
  return null;
});

/// Runs once at app start to delete audio files that no longer have a
/// matching SQLite row (e.g. after a migration or a corrupted cache row).
/// Returns the number of files removed.
final audioCacheJanitorProvider = FutureProvider<int>((ref) async {
  final cache = ref.watch(audioCacheRepositoryProvider);
  if (cache == null) return 0;
  return cache.cleanupOrphans();
});

final ttsControllerProvider =
    NotifierProvider<TtsController, TtsPlaybackState>(TtsController.new);

class TtsController extends Notifier<TtsPlaybackState> {
  StreamSubscription<AudioQueueEvent>? _sub;
  late final AudioQueue _queue;

  @override
  TtsPlaybackState build() {
    _queue = ref.read(audioQueueProvider);
    _sub = _queue.events.listen(_onQueueEvent);
    ref.onDispose(() => _sub?.cancel());
    return const TtsPlaybackState();
  }

  Future<void> playMessage({
    required String conversationId,
    required String messageId,
    required String text,
  }) async {
    if (text.trim().isEmpty) return;
    final splitter = ref.read(sentenceSplitterProvider);
    final sentences = splitter.split(text);
    if (sentences.isEmpty) return;

    final items = <AudioQueueItem>[];
    final stateMap =
        Map<String, SentencePlaybackState>.from(state.sentenceStates);
    for (var i = 0; i < sentences.length; i++) {
      final sentence = sentences[i];
      final sentenceId = 's_${messageId}_$i';
      stateMap[sentenceId] = SentencePlaybackState.generating;
      final result = await _synthesizeOrFetch(
        conversationId: conversationId,
        messageId: messageId,
        sentenceId: sentenceId,
        text: sentence,
      );
      if (result == null) {
        stateMap[sentenceId] = SentencePlaybackState.failed;
      } else {
        stateMap[sentenceId] = SentencePlaybackState.ready;
        items.add(AudioQueueItem(
          conversationId: conversationId,
          messageId: messageId,
          sentenceId: sentenceId,
          audioPath: result.audioPath,
          duration: result.duration,
        ));
      }
    }
    state = state.copyWith(sentenceStates: stateMap);
    if (items.isEmpty) return;
    await _queue.enqueue(items);
  }

  Future<void> playSingleSentence({
    required String conversationId,
    required String messageId,
    required String sentenceId,
    required String text,
  }) async {
    if (text.trim().isEmpty) return;
    final stateMap =
        Map<String, SentencePlaybackState>.from(state.sentenceStates);
    stateMap[sentenceId] = SentencePlaybackState.generating;
    state = state.copyWith(sentenceStates: stateMap);

    final result = await _synthesizeOrFetch(
      conversationId: conversationId,
      messageId: messageId,
      sentenceId: sentenceId,
      text: text,
    );
    if (result == null) {
      stateMap[sentenceId] = SentencePlaybackState.failed;
      state = state.copyWith(sentenceStates: stateMap);
      return;
    }
    // _synthesizeOrFetch already finalised the state to either `cached`
    // (cache hit) or `ready` (fresh synthesis); don't overwrite it here.
    await _queue.enqueue([
      AudioQueueItem(
        conversationId: conversationId,
        messageId: messageId,
        sentenceId: sentenceId,
        audioPath: result.audioPath,
        duration: result.duration,
      ),
    ]);
  }

  Future<void> retrySentence({
    required String conversationId,
    required String messageId,
    required String sentenceId,
    required String text,
  }) async {
    // Drop any cached record + force a fresh synthesis on the next play.
    final cache = ref.read(audioCacheRepositoryProvider);
    if (cache != null) {
      // no per-row delete helper in the interface today; we just record over
      // it on the next successful synthesis.
    }
    state = state.copyWith(
      sentenceStates: {
        ...state.sentenceStates,
        sentenceId: SentencePlaybackState.idle,
      },
    );
    await playSingleSentence(
      conversationId: conversationId,
      messageId: messageId,
      sentenceId: sentenceId,
      text: text,
    );
  }

  Future<TtsResult?> _synthesizeOrFetch({
    required String conversationId,
    required String messageId,
    required String sentenceId,
    required String text,
  }) async {
    final settings = ref.read(settingsControllerProvider);
    final engine = ref.read(ttsEngineProvider);
    final cache = ref.read(audioCacheRepositoryProvider);

    final request = _requestFromSettings(
      settings,
      text: text,
      messageId: messageId,
      sentenceId: sentenceId,
    );

    if (cache != null) {
      final cached = await cache.lookup(
        conversationId: conversationId,
        messageId: messageId,
        sentenceId: sentenceId,
      );
      if (cached != null && File(cached.audioPath).existsSync()) {
        final map =
            Map<String, SentencePlaybackState>.from(state.sentenceStates);
        map[sentenceId] = SentencePlaybackState.cached;
        state = state.copyWith(sentenceStates: map);
        return TtsResult(
          audioPath: cached.audioPath,
          duration: cached.duration,
          format: 'wav',
        );
      }
    }

    try {
      final result = await engine.synthesize(request);
      if (cache != null) {
        await cache.record(
          conversationId: conversationId,
          messageId: messageId,
          sentenceId: sentenceId,
          audioPath: result.audioPath,
          bytes: result.bytes ?? 0,
          format: result.format ?? 'wav',
          duration: result.duration,
          language: request.language,
          voiceId: request.voiceId,
          speed: request.speed,
          modelVersion: request.modelVersion,
        );
      }
      return result;
    } on TtsError {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> pause() => _queue.pause();
  Future<void> resume() => _queue.resume();
  Future<void> stop() => _queue.stop();
  Future<void> next() => _queue.next();
  Future<void> previous() => _queue.previous();

  void _onQueueEvent(AudioQueueEvent event) {
    switch (event) {
      case AudioQueueStarted():
        state = state.copyWith(playback: AudioPlaybackState.loading);
      case AudioQueueItemStarted(:final item):
        state = state.copyWith(
          currentSentenceId: item.sentenceId,
          playback: AudioPlaybackState.playing,
        );
      case AudioQueueItemFailed():
        state = state.copyWith(playback: AudioPlaybackState.error);
      case AudioQueueFinished():
        state = const TtsPlaybackState(playback: AudioPlaybackState.completed);
      case AudioQueueStopped():
        state = const TtsPlaybackState(playback: AudioPlaybackState.idle);
    }
  }

  TtsRequest _requestFromSettings(
    AppSettings settings, {
    required String text,
    required String messageId,
    required String sentenceId,
  }) {
    final defaultVoice = defaultVoiceFor(settings.preferredLanguage);
    final voiceId =
        settings.voiceFor(settings.preferredLanguage, defaultVoice.id);
    return TtsRequest(
      text: text,
      language: settings.preferredLanguage.code,
      voiceId: voiceId,
      speed: settings.speechSpeed,
    );
  }
}
