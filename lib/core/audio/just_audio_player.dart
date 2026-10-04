import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'audio_player.dart';

/// `just_audio` backed [AudioPlayerService]. Used on real Android devices;
/// host tests fall back to [InMemoryAudioPlayer].
class JustAudioPlayer implements AudioPlayerService {
  JustAudioPlayer() : _player = AudioPlayer();

  final AudioPlayer _player;
  final _stateController = StreamController<AudioPlaybackState>.broadcast();
  StreamSubscription<PlayerState>? _playerStateSub;
  AudioPlaybackState _state = AudioPlaybackState.idle;

  @override
  AudioPlaybackState get state => _state;

  @override
  Stream<AudioPlaybackState> get stateStream => _stateController.stream;

  @override
  Future<void> load(String audioPath) async {
    _playerStateSub ??= _player.playerStateStream.listen(_onPlayerState);
    await _player.setFilePath(audioPath);
    _emit(AudioPlaybackState.loading);
  }

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> resume() async {
    await _player.play();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _emit(AudioPlaybackState.idle);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> release() async {
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _player.dispose();
    await _stateController.close();
  }

  @override
  Duration? get position => _player.position;

  void _onPlayerState(PlayerState next) {
    if (next.processingState == ProcessingState.completed) {
      _emit(AudioPlaybackState.completed);
      return;
    }
    if (next.playing) {
      _emit(AudioPlaybackState.playing);
    } else if (next.processingState == ProcessingState.buffering ||
        next.processingState == ProcessingState.loading) {
      _emit(AudioPlaybackState.loading);
    } else {
      _emit(AudioPlaybackState.paused);
    }
  }

  void _emit(AudioPlaybackState next) {
    _state = next;
    _stateController.add(next);
  }
}
