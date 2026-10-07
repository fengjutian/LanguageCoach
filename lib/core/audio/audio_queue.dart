import 'dart:async';

import 'audio_player.dart';

/// One entry inside the [AudioQueue]. Carries enough context for the UI to
/// render the right bubble as the currently-playing sentence and so the
/// cache layer can look up the file path on disk.
class AudioQueueItem {
  const AudioQueueItem({
    required this.conversationId,
    required this.messageId,
    required this.sentenceId,
    required this.audioPath,
    this.duration,
  });
  final String conversationId;
  final String messageId;
  final String sentenceId;
  final String audioPath;
  final Duration? duration;
}

/// Plays a queue of pre-synthesised audio items sequentially. Each item is
/// handed to [AudioPlayerService]; failures on one item do not abort the
/// queue unless [stopOnError] is true (default).
///
/// The queue guarantees:
///   * Only one audio source plays at a time.
///   * A new [enqueue] call cancels whatever was queued or playing.
///   * `dispose()` releases the underlying player.
class AudioQueue {
  AudioQueue({
    required AudioPlayerService player,
    this.stopOnError = false,
    this.releasePlayerOnDispose = false,
  }) : _player = player {
    _stateSub = player.stateStream.listen(_onPlayerState);
  }

  final AudioPlayerService _player;
  final bool stopOnError;

  /// The player is *injected*, so this queue normally does not own it:
  /// `main.dart` installs one shared `JustAudioPlayer` that the practice
  /// pages read through `audioPlayerServiceProvider` too. Releasing it on
  /// dispose closed the shared player's state controller out from under
  /// them. Only set this when the caller handed over sole ownership.
  final bool releasePlayerOnDispose;

  final _controller = StreamController<AudioQueueEvent>.broadcast();
  StreamSubscription<AudioPlaybackState>? _stateSub;

  List<AudioQueueItem> _items = const <AudioQueueItem>[];
  int _cursor = 0;
  bool _playing = false;

  Stream<AudioQueueEvent> get events => _controller.stream;

  /// Replace the queue with [items] and start playback from the beginning.
  Future<void> enqueue(List<AudioQueueItem> items) async {
    if (items.isEmpty) return;
    await _player.stop();
    _items = List.unmodifiable(items);
    _cursor = 0;
    _playing = true;
    _controller.add(AudioQueueStarted(items));
    await _playCurrent();
  }

  Future<void> pause() async {
    if (_state != AudioPlaybackState.playing) return;
    await _player.pause();
  }

  Future<void> resume() async {
    if (_state != AudioPlaybackState.paused) return;
    await _player.resume();
  }

  Future<void> stop() async {
    _items = const <AudioQueueItem>[];
    _cursor = 0;
    _playing = false;
    await _player.stop();
    _controller.add(AudioQueueStopped());
  }

  Future<void> next() async {
    if (_cursor + 1 >= _items.length) {
      await stop();
      return;
    }
    _cursor += 1;
    await _playCurrent();
  }

  Future<void> previous() async {
    if (_cursor <= 0) return;
    _cursor -= 1;
    await _playCurrent();
  }

  Future<void> dispose() async {
    await _stateSub?.cancel();
    _stateSub = null;
    if (releasePlayerOnDispose) {
      await _player.release();
    }
    await _controller.close();
  }

  AudioQueueItem? get currentItem =>
      (_playing && _cursor < _items.length) ? _items[_cursor] : null;

  AudioPlaybackState get _state => _player.state;

  Future<void> _playCurrent() async {
    if (_cursor >= _items.length) {
      _playing = false;
      _controller.add(AudioQueueFinished());
      return;
    }
    final item = _items[_cursor];
    try {
      await _player.load(item.audioPath);
      await _player.play();
      _controller.add(AudioQueueItemStarted(item));
    } catch (e) {
      _controller.add(AudioQueueItemFailed(item, e.toString()));
      if (stopOnError) {
        await stop();
      } else {
        await next();
      }
    }
  }

  void _onPlayerState(AudioPlaybackState next) {
    if (next == AudioPlaybackState.completed &&
        _playing &&
        _player.state == AudioPlaybackState.completed) {
      // Auto-advance when the player finishes a sentence. Guard on
      // `_playing` so a duplicated or late completion event after the
      // queue already drained can't re-enter _playCurrent and emit
      // another `AudioQueueFinished`.
      _cursor += 1;
      unawaited(_playCurrent());
    }
  }
}

sealed class AudioQueueEvent {
  const AudioQueueEvent();
}

class AudioQueueStarted extends AudioQueueEvent {
  const AudioQueueStarted(this.items);
  final List<AudioQueueItem> items;
}

class AudioQueueItemStarted extends AudioQueueEvent {
  const AudioQueueItemStarted(this.item);
  final AudioQueueItem item;
}

class AudioQueueItemFailed extends AudioQueueEvent {
  const AudioQueueItemFailed(this.item, this.message);
  final AudioQueueItem item;
  final String message;
}

class AudioQueueFinished extends AudioQueueEvent {
  const AudioQueueFinished();
}

class AudioQueueStopped extends AudioQueueEvent {
  const AudioQueueStopped();
}
