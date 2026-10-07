import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/audio_cache.dart';
import '../../../core/audio/audio_player.dart';
import '../../../core/audio/audio_queue.dart';
import '../../../core/audio/minimax_tts_engine.dart';
import '../../../core/audio/native_qwen_tts_engine.dart';
import '../../../core/audio/sentence_splitter.dart';
import '../../../core/audio/tts_engine.dart';
import '../../../core/audio/tts_models.dart';
import '../../../core/audio/voice_profile.dart';
import '../../../core/models/app_settings.dart';
import '../../../core/security/secure_key_store.dart';
import '../../settings/application/settings_controller.dart';
import 'conversation_providers.dart';

/// State exposed to widgets that surface a sentence-level play / pause
/// indicator. The shape is deliberately minimal so MessageBubble can
/// rebuild cheaply when only the active sentence changes.
class TtsPlaybackState {
  const TtsPlaybackState({
    this.currentSentenceId,
    this.playback = AudioPlaybackState.idle,
    this.queueLength = 0,
    this.sentenceStates = const <String, SentencePlaybackState>{},
    this.lastError,
  });

  final String? currentSentenceId;
  final AudioPlaybackState playback;
  final int queueLength;
  final Map<String, SentencePlaybackState> sentenceStates;

  /// Most recent synthesis error surfaced to the UI. Populated when
  /// the active engine throws [TtsError] (network, format, missing key,
  /// upstream status_code != 0). Cleared once the user retries — a stale
  /// message would otherwise stay attached to a sentence that has since
  /// started a fresh synthesis.
  final TtsError? lastError;

  TtsPlaybackState copyWith({
    String? currentSentenceId,
    AudioPlaybackState? playback,
    int? queueLength,
    Map<String, SentencePlaybackState>? sentenceStates,
    bool clearCurrentSentence = false,
    TtsError? lastError,
    bool clearLastError = false,
  }) {
    return TtsPlaybackState(
      currentSentenceId: clearCurrentSentence
          ? null
          : (currentSentenceId ?? this.currentSentenceId),
      playback: playback ?? this.playback,
      queueLength: queueLength ?? this.queueLength,
      sentenceStates: sentenceStates ?? this.sentenceStates,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
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

/// Snapshot of the MiniMax API key configured for cloud synthesis.
/// `null` (or an empty string) means the cloud engine is unavailable
/// and the runtime falls back to the off-platform stub.
final miniMaxTtsApiKeyProvider = FutureProvider<String?>((ref) async {
  final store = ref.read(secureKeyStoreProvider);
  return store.read(ApiKeySlot.miniMax);
});

final ttsEngineProvider = Provider<TtsEngine>((ref) {
  final outputDir = ref.watch(ttsOutputDirectoryProvider);
  final config = ref.watch(appConfigProvider);
  // Watch the cached API key. When the user has entered a MiniMax key the
  // runtime swaps the off-platform stub for a cloud-backed engine — that
  // is the path that lets the app do cloud TTS while bypassing the ~860 MB
  // Qwen3-TTS GGUF download. The actual switch is below.
  final apiKey = ref.watch(miniMaxTtsApiKeyProvider).maybeWhen(
        data: (k) => k,
        orElse: () => null,
      );
  if (apiKey != null && apiKey.isNotEmpty) {
    return MinimaxTtsEngine(
      dio: Dio(),
      apiKeyResolver: () async => apiKey,
      outputDirectory: outputDir,
      // Keep chat and speech on the same MiniMax region. MiniMax keys cannot
      // be used interchangeably between api.minimaxi.com and api.minimax.io.
      baseUrl: config.miniMax.baseUrl,
    );
  }
  // Without a cloud key, use Android's installed speech engine. The native
  // bridge automatically prefers a loaded Qwen model and otherwise writes
  // system TTS output to a real WAV file. The old fallback generated an empty
  // WAV header, which made playback appear successful while remaining silent.
  return NativeQwenTtsEngine(
    bridge: ref.watch(nativeAiBridgeProvider),
    modelId: 'system',
    id: 'android-system-tts',
  );
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

  /// Latched playback failure, see [_onQueueEvent].
  String? _playbackFailure;

  /// Guards against a double-tap on the play button starting two concurrent
  /// synthesis fans. `AudioQueue.enqueue` awaits `_player.stop()` before
  /// mutating state, so the two runs interleaved and could emit a stale
  /// `AudioQueueItemStarted` for the wrong message.
  String? _playingMessageId;

  /// Upper bound for one synthesis round-trip.
  static const Duration _synthesisTimeout = Duration(seconds: 45);

  @override
  TtsPlaybackState build() {
    _queue = ref.read(audioQueueProvider);
    // Cancel the previous subscription before replacing it, otherwise
    // every rebuild stacks a new listener and every queue event fires
    // N times. Same fix as model_controller (commit 135a2dc).
    _sub?.cancel();
    _playbackFailure = null;
    _sub = _queue.events.listen(_onQueueEvent);
    ref.onDispose(() => _sub?.cancel());
    return const TtsPlaybackState();
  }

  Future<void> playMessage({
    required String conversationId,
    required String messageId,
    required String text,
    String? languageCode,
    /// The caller's own sentence enumeration. The UI renders
    /// `response.sentences` and derives each tile's id from its index, so
    /// re-splitting `text` here could produce a *different* number of
    /// sentences than the tiles. The indexes then disagreed, states were
    /// written under ids no tile renders, and a tile could resolve the audio
    /// cache to another sentence's clip. When provided, this is the single
    /// source of truth for both sides.
    List<String>? sentences,
  }) async {
    if (text.trim().isEmpty) return;
    // A new playback attempt clears the latched failure from the previous one.
    _playbackFailure = null;
    final splitter = ref.read(sentenceSplitterProvider);
    final parts = (sentences != null && sentences.isNotEmpty)
        ? sentences.where((s) => s.trim().isNotEmpty).toList(growable: false)
        : splitter.split(text);
    if (parts.isEmpty) return;
    if (_playingMessageId == messageId) return;
    _playingMessageId = messageId;

    // Mark every sentence as generating up-front so the UI shows the
    // spinner for the whole message, not a one-by-one reveal. Then fan
    // the synthesis out in parallel — a 10-sentence reply no longer
    // waits 9 rounds of network before the first clip plays.
    final stateMap =
        Map<String, SentencePlaybackState>.from(state.sentenceStates);
    final ids = <String>[];
    final texts = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final id = 's_${messageId}_$i';
      ids.add(id);
      texts.add(parts[i]);
      stateMap[id] = SentencePlaybackState.generating;
    }
    state = state.copyWith(sentenceStates: stateMap);

    final outcomes = await Future.wait(<Future<
        ({
          TtsResult? result,
          TtsError? error,
          SentencePlaybackState sentenceState,
        })>>[
      for (var i = 0; i < ids.length; i++)
        _synthesizeOrFetch(
          conversationId: conversationId,
          messageId: messageId,
          sentenceId: ids[i],
          text: texts[i],
          languageCode: languageCode,
        ),
    ]);

    final items = <AudioQueueItem>[];
    var clearError = true;
    var lastError = state.lastError;
    for (var i = 0; i < outcomes.length; i++) {
      final id = ids[i];
      final outcome = outcomes[i];
      final result = outcome.result;
      stateMap[id] = outcome.sentenceState;
      if (result == null) {
        // Keep the most recent failure. The clearError flag flips to
        // false the moment any sentence fails so a partial success
        // can't wipe a sibling sentence's error message.
        if (outcome.error != null) lastError = outcome.error;
        clearError = false;
        continue;
      }
      items.add(AudioQueueItem(
        conversationId: conversationId,
        messageId: messageId,
        sentenceId: id,
        audioPath: result.audioPath,
        duration: result.duration,
      ));
    }
    state = clearError
        ? state.copyWith(sentenceStates: stateMap, clearLastError: true)
        : state.copyWith(sentenceStates: stateMap, lastError: lastError);
    if (items.isEmpty) {
      _playingMessageId = null;
      return;
    }
    await _queue.enqueue(items);
    _playingMessageId = null;
  }

  Future<void> playSingleSentence({
    required String conversationId,
    required String messageId,
    required String sentenceId,
    required String text,
    String? languageCode,
  }) async {
    if (text.trim().isEmpty) return;
    _playbackFailure = null;
    final stateMap =
        Map<String, SentencePlaybackState>.from(state.sentenceStates);
    stateMap[sentenceId] = SentencePlaybackState.generating;
    state = state.copyWith(sentenceStates: stateMap);

    final outcome = await _synthesizeOrFetch(
      conversationId: conversationId,
      messageId: messageId,
      sentenceId: sentenceId,
      text: text,
      languageCode: languageCode,
    );
    final result = outcome.result;
    stateMap[sentenceId] = outcome.sentenceState;
    if (result == null) {
      state =
          state.copyWith(sentenceStates: stateMap, lastError: outcome.error);
      return;
    }
    state = state.copyWith(sentenceStates: stateMap, clearLastError: true);
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
    String? languageCode,
  }) async {
    // Drop the cached row + audio file so the next lookup misses and the
    // engine re-synthesises from scratch — without this the user kept
    // hearing the same broken clip.
    final cache = ref.read(audioCacheRepositoryProvider);
    if (cache != null) {
      await cache.invalidate(
        conversationId: conversationId,
        messageId: messageId,
        sentenceId: sentenceId,
      );
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
      languageCode: languageCode,
    );
  }

  /// Pure synthesis + cache lookup. Returns the [TtsResult] on success,
  /// the typed [TtsError] on failure, and the per-sentence playback
  /// state to record; the caller folds everything into the state
  /// atomically so concurrent invocations from [playMessage] don't
  /// trample each other's snapshot reads.
  Future<
      ({
        TtsResult? result,
        TtsError? error,
        SentencePlaybackState sentenceState,
      })> _synthesizeOrFetch({
    required String conversationId,
    required String messageId,
    required String sentenceId,
    required String text,
    String? languageCode,
  }) async {
    final settings = ref.read(settingsControllerProvider);
    final engine = ref.read(ttsEngineProvider);
    final cache = ref.read(audioCacheRepositoryProvider);

    final request = _requestFromSettings(
      settings,
      text: text,
      messageId: messageId,
      sentenceId: sentenceId,
      languageCode: languageCode,
    );

    if (cache != null) {
      final cached = await cache.lookup(
        conversationId: conversationId,
        messageId: messageId,
        sentenceId: sentenceId,
      );
      if (cached != null && _containsAudio(File(cached.audioPath))) {
        return (
          result: TtsResult(
            audioPath: cached.audioPath,
            duration: cached.duration,
            format: 'wav',
          ),
          error: null,
          sentenceState: SentencePlaybackState.cached,
        );
      }
    }

    try {
      // A wedged engine used to pin `chatSessionPhaseProvider` at
      // `processing` forever: no timeout, no error, the bubble kept
      // spinning and the stop button was the only escape.
      final result = await engine.synthesize(request).timeout(
            _synthesisTimeout,
            onTimeout: () => throw TtsError(
              TtsErrorKind.unknown,
              '语音合成超时（${_synthesisTimeout.inSeconds} 秒）',
            ),
          );
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
      return (
        result: result,
        error: null,
        sentenceState: SentencePlaybackState.ready,
      );
    } on TtsError catch (e) {
      // Surface the typed failure to the UI instead of swallowing it —
      // the previous version silently turned every engine error into a
      // blank "no sound" UX with no way to tell whether the cause was
      // a missing key, a network blip, or a malformed payload. Use
      // [developer.log] so the message reaches `adb logcat` on top of
      // any UI surface, which is essential when the only feedback is a
      // silent failure.
      developer.log(
        'TTS synthesis failed: $e',
        name: 'tts_controller',
        error: e,
      );
      return (
        result: null,
        error: e,
        sentenceState: SentencePlaybackState.failed,
      );
    } catch (e, st) {
      developer.log(
        'TTS unexpected error: $e',
        name: 'tts_controller',
        error: e,
        stackTrace: st,
      );
      return (
        result: null,
        error: TtsError(TtsErrorKind.unknown, e.toString()),
        sentenceState: SentencePlaybackState.failed,
      );
    }
  }

  bool _containsAudio(File file) {
    if (!file.existsSync()) return false;
    final length = file.lengthSync();
    if (length != 44) return length > 0;
    // The former fallback cached a header-only PCM WAV. Do not keep replaying
    // those silent artifacts after a real speech engine becomes available.
    final bytes = file.readAsBytesSync();
    final isWav = bytes.length == 44 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46;
    final hasNoPcmData =
        bytes.length >= 44 && bytes.sublist(40, 44).every((byte) => byte == 0);
    return !(isWav && hasNoPcmData);
  }

  Future<void> pause() => _queue.pause();
  Future<void> resume() => _queue.resume();
  Future<void> stop() async {
    _playbackFailure = null;
    if (state.playback == AudioPlaybackState.error) {
      state = state.copyWith(playback: AudioPlaybackState.idle);
    }
    return _queue.stop();
  }
  Future<void> next() => _queue.next();
  Future<void> previous() => _queue.previous();

  void _onQueueEvent(AudioQueueEvent event) {
    switch (event) {
      case AudioQueueStarted():
        if (_playbackFailure != null) return;
        state = state.copyWith(playback: AudioPlaybackState.loading);
      case AudioQueueItemStarted(:final item):
        if (_playbackFailure != null) return;
        state = state.copyWith(
          currentSentenceId: item.sentenceId,
          playback: AudioPlaybackState.playing,
        );
      case AudioQueueItemFailed(:final item, :final message):
        // The queue keeps going by default (`stopOnError: false`) and emits
        // ItemStarted/Stopped immediately after, which used to overwrite this
        // error in the very same frame — so `chatSessionErrorProvider` never
        // saw it and the retry card never appeared. Latch until the user
        // starts a new playback.
        _playbackFailure = message;
        state = state.copyWith(
          playback: AudioPlaybackState.error,
          currentSentenceId: item.sentenceId,
          sentenceStates: <String, SentencePlaybackState>{
            ...state.sentenceStates,
            item.sentenceId: SentencePlaybackState.failed,
          },
        );
      case AudioQueueFinished():
        if (_playbackFailure != null) return;
        // Preserve per-sentence states (cached / ready / failed) so the
        // UI keeps showing what's already on disk and re-plays skip the
        // cold path. The previous `const TtsPlaybackState(...)` reset
        // wiped the whole state map, hiding the cache.
        state = state.copyWith(playback: AudioPlaybackState.completed);
      case AudioQueueStopped():
        if (_playbackFailure != null) return;
        state = state.copyWith(playback: AudioPlaybackState.idle);
    }
  }

  TtsRequest _requestFromSettings(
    AppSettings settings, {
    required String text,
    required String messageId,
    required String sentenceId,
    String? languageCode,
  }) {
    final language = languageCode == null
        ? settings.preferredLanguage
        : CoachLanguage.values.firstWhere(
            (item) => item.code == languageCode,
            orElse: () => settings.preferredLanguage,
          );
    final defaultVoice = defaultVoiceFor(language);
    final voiceId = settings.voiceFor(language, defaultVoice.id);
    return TtsRequest(
      text: text,
      language: language.code,
      voiceId: voiceId,
      speed: settings.speechSpeed,
    );
  }
}
