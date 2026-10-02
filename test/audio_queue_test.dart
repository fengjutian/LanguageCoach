import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/core/audio/audio_queue.dart';

AudioQueueItem _item(int i) => AudioQueueItem(
      conversationId: 'c1',
      messageId: 'm',
      sentenceId: 's_$i',
      audioPath: '/tmp/$i.wav',
    );

void main() {
  test('enqueue plays sequentially and emits started events', () async {
    final player = InMemoryAudioPlayer();
    final queue = AudioQueue(player: player);
    addTearDown(queue.dispose);

    final events = <AudioQueueEvent>[];
    final sub = queue.events.listen(events.add);
    // broadcast streams drop events fired before the listener attaches; let
    // the listener settle first.
    await Future<void>.delayed(Duration.zero);

    await queue.enqueue([_item(0), _item(1)]);
    await Future<void>.delayed(Duration.zero);

    expect(queue.currentItem?.sentenceId, 's_0');
    expect(player.state, AudioPlaybackState.playing);
    expect(events.whereType<AudioQueueStarted>().length, 1);
    expect(events.whereType<AudioQueueItemStarted>().length, 1);

    await sub.cancel();
  });

  test('finishForTest auto-advances to the next item', () async {
    final player = InMemoryAudioPlayer();
    final queue = AudioQueue(player: player);
    addTearDown(queue.dispose);

    await queue.enqueue([_item(0), _item(1)]);
    player.finishForTest(); // simulate s_0 completing
    await Future<void>.delayed(Duration.zero);
    expect(queue.currentItem?.sentenceId, 's_1');
    expect(player.state, AudioPlaybackState.playing);

    player.finishForTest(); // s_1 completes -> queue finishes
    await Future<void>.delayed(Duration.zero);
    expect(queue.currentItem, isNull);
  });

  test('stop clears the queue', () async {
    final player = InMemoryAudioPlayer();
    final queue = AudioQueue(player: player);
    addTearDown(queue.dispose);

    await queue.enqueue([_item(0), _item(1)]);
    await queue.stop();
    expect(queue.currentItem, isNull);
    expect(player.state, AudioPlaybackState.idle);
  });

  test('previous rewinds one step', () async {
    final player = InMemoryAudioPlayer();
    final queue = AudioQueue(player: player);
    addTearDown(queue.dispose);

    await queue.enqueue([_item(0), _item(1)]);
    player.finishForTest(); // move to s_1
    await Future<void>.delayed(Duration.zero);
    await queue.previous();
    expect(queue.currentItem?.sentenceId, 's_0');
  });
}
