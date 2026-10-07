import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/sentence_splitter.dart';

void main() {
  const splitter = SentenceSplitter();

  test('empty input returns empty list', () {
    expect(splitter.split(''), isEmpty);
    expect(splitter.split('   '), isEmpty);
  });

  test('splits on English sentence boundaries', () {
    expect(splitter.split('Hello world. How are you? Fine!'),
        ['Hello world.', 'How are you?', 'Fine!']);
  });

  test('splits on Chinese sentence boundaries', () {
    expect(splitter.split('你好。今天怎么样？不错！'), ['你好。', '今天怎么样？', '不错！']);
  });

  test('keeps English honorifics attached', () {
    final out = splitter.split('We met Mr. Smith today. He left.');
    expect(out.first, startsWith('We met Mr. Smith today.'));
  });

  test('keeps e.g. attached to previous sentence', () {
    final out = splitter.split('We have options e.g. train or bus.');
    expect(out.first, contains('e.g.'));
    expect(out.length, lessThanOrEqualTo(2));
  });

  test('does not split on commas', () {
    final out = splitter.split('one, two, three');
    expect(out, ['one, two, three']);
  });

  test('breaks long sentences by word boundary', () {
    final long = 'word ' * 80; // 5*80 = 400 chars, well over the 200 cap
    final out = splitter.split(long.trim());
    expect(out.length, greaterThan(1));
    for (final piece in out) {
      expect(piece.length, lessThanOrEqualTo(220));
    }
  });

  test('mixed-script paragraph', () {
    final out = splitter.split('Hola. 你好。 Bonjour!');
    expect(out, ['Hola.', '你好。', 'Bonjour!']);
  });

  test('does not split inside a decimal number', () {
    // A `.` between digits is a decimal point. Splitting here produced
    // "Pi is 3." + "14.", i.e. two TTS requests mid-number.
    final out = splitter.split('Pi is 3.14.');
    expect(out, hasLength(1));
    expect(out.first.trim(), 'Pi is 3.14.');
  });

  test('still splits a real sentence after a decimal', () {
    final out = splitter.split('The value is 2.5. That is all.');
    expect(out, hasLength(2));
    expect(out.first.trim(), 'The value is 2.5.');
    expect(out.last.trim(), 'That is all.');
  });

  test('ellipsis produces a single boundary', () {
    final out = splitter.split('Wait... what happened?');
    expect(out, hasLength(2));
    expect(out.first.trim(), 'Wait...');
    expect(out.last.trim(), 'what happened?');
  });
}
