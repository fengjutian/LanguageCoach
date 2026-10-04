import 'dart:async';

/// State surface for the audio pipeline. UI uses this to know whether to
/// show a play / pause / loading indicator. The model is intentionally tiny
/// so widgets can rebuild cheaply.
enum AudioPlaybackState { idle, loading, playing, paused, completed, error }

/// Thin, queue-agnostic audio control surface. `just_audio` is the default
/// implementation; tests inject [InMemoryAudioPlayer] so the queue logic
/// can run in a host VM.
abstract interface class AudioPlayerService {
  AudioPlaybackState get state;

  Stream<AudioPlaybackState> get stateStream;

  Future<void> load(String audioPath);

  Future<void> play();

  Future<void> pause();

  Future<void> resume();

  Future<void> stop();

  Future<void> seek(Duration position);

  Future<void> setSpeed(double speed);

  Future<void> release();

  Duration? get position;
}

/// Test double. Plays pretend — emits `playing → completed` on `play()` and
/// tracks state in a private field. Useful for the queue + UI tests.
class InMemoryAudioPlayer implements AudioPlayerService {
  InMemoryAudioPlayer();

  final _stateController = StreamController<AudioPlaybackState>.broadcast();
  AudioPlaybackState _state = AudioPlaybackState.idle;
  Duration _position = Duration.zero;

  @override
  AudioPlaybackState get state => _state;

  @override
  Stream<AudioPlaybackState> get stateStream => _stateController.stream;

  @override
  Future<void> load(String audioPath) async {
    _emit(AudioPlaybackState.loading);
  }

  @override
  Future<void> play() async {
    _emit(AudioPlaybackState.playing);
  }

  @override
  Future<void> pause() async {
    _emit(AudioPlaybackState.paused);
  }

  @override
  Future<void> resume() async {
    _emit(AudioPlaybackState.playing);
  }

  @override
  Future<void> stop() async {
    _position = Duration.zero;
    _emit(AudioPlaybackState.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = position;
  }

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> release() async {
    _emit(AudioPlaybackState.idle);
    await _stateController.close();
  }

  @override
  Duration? get position => _position;

  /// Test hook — advance the in-memory state as if the audio file finished.
  void finishForTest() {
    _emit(AudioPlaybackState.completed);
  }

  void _emit(AudioPlaybackState next) {
    _state = next;
    _stateController.add(next);
  }
}
