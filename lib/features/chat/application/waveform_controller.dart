import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'conversation_providers.dart';

/// Ring buffer of recent RMS samples. Length is bounded so the UI repaint
/// stays cheap even during long capture sessions. ~60 samples × 60 ms =
/// ~3.5 s of audio, enough to render a visible waveform.
const int _waveformCapacity = 60;

/// State surface for the waveform widget. We keep it as a plain list so
/// the painter can index into it without copying.
class WaveformState {
  const WaveformState({this.levels = const <double>[]});
  final List<double> levels;

  WaveformState copyWith({List<double>? levels}) =>
      WaveformState(levels: levels ?? this.levels);
}

/// Listens to the bridge `eventStream`, picks out the `ASR_LEVEL` frames,
/// and stores the most recent levels in a bounded buffer. Cleared whenever
/// the consumer stops listening — the chat page resets the buffer when
/// the recording phase ends.
final waveformControllerProvider =
    NotifierProvider<WaveformController, WaveformState>(
  WaveformController.new,
);

class WaveformController extends Notifier<WaveformState> {
  static const double _referenceDb = -2.0;
  static const double _floorDb = -30.0;

  StreamSubscription<Object?>? _sub;
  final Queue<double> _levels = ListQueue<double>();

  @override
  WaveformState build() {
    final bridge = ref.watch(nativeAiBridgeProvider);
    // `build` re-runs whenever the watched bridge changes. Overwriting `_sub`
    // without cancelling first leaked the previous listener (and `onDispose`
    // only ever cancelled the newest one), so stale frames kept writing
    // `state` on a stale notifier instance.
    unawaited(_sub?.cancel());
    _sub = bridge.eventStream.listen(_onEvent);
    ref.onDispose(() {
      final sub = _sub;
      _sub = null;
      unawaited(sub?.cancel());
    });
    _levels.clear();
    return const WaveformState();
  }

  void _onEvent(Object? frame) {
    if (frame is! Map) return;
    final type = frame['type'];
    if (type is! String || type != 'ASR_LEVEL') return;
    final payload = frame['payload'];
    if (payload is! Map) return;
    final raw = payload['level'];
    final db = raw is num ? raw.toDouble() : null;
    if (db == null) return;
    _levels.addLast(_normalize(db));
    while (_levels.length > _waveformCapacity) {
      _levels.removeFirst();
    }
    state = WaveformState(levels: _levels.toList(growable: false));
  }

  /// Clear the buffer. Called by the chat page when recording ends so
  /// the next session starts with a fresh waveform.
  void reset() {
    _levels.clear();
    state = const WaveformState();
  }

  /// Map a dBFS reading (typically negative — `-2` ≈ full scale, `-30` ≈
  /// silence) into a `[0, 1]` amplitude. Anything quieter than the floor
  /// maps to 0 so the painter still shows a flat baseline.
  static double _normalize(double db) {
    if (db >= _referenceDb) return 1;
    if (db <= _floorDb) return 0;
    final span = _referenceDb - _floorDb;
    return ((db - _floorDb) / span).clamp(0.0, 1.0);
  }
}