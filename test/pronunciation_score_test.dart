import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/features/practice/domain/pronunciation_score.dart';

void main() {
  const scorer = TranscriptPronunciationScorer();

  test('exact transcript receives full text-alignment scores', () async {
    final score = await scorer.score(
      reference: 'Could you say that one more time?',
      transcript: 'Could you say that one more time?',
      duration: const Duration(seconds: 3),
    );
    expect(score.accuracy, 100);
    expect(score.completeness, 100);
    expect(score.phoneme, 100);
    expect(score.overall, greaterThanOrEqualTo(90));
  });

  test('normal CJK delivery is not penalised as "too fast"', () async {
    // 11 characters read in 2 seconds ≈ 5.5 chars/s, which is conversational
    // Mandarin pace. `_tokens` counts CJK per character, so the latin
    // 70-190 wpm window used to score this at ~330 "wpm" and permanently
    // subtract ~49 fluency points while advising the user to slow down.
    const reference = '今天天气真不错。';
    final score = await scorer.score(
      reference: reference,
      transcript: reference,
      duration: const Duration(seconds: 2),
    );
    expect(score.accuracy, 100);
    expect(score.completeness, 100);
    expect(score.fluency, greaterThanOrEqualTo(90));
    expect(score.feedback, isNot(contains('注意连贯表达，减少停顿或抢读。')));
  });

  test('genuinely rushed CJK still loses fluency', () async {
    // 11 characters in 0.3s ≈ 22 chars/s — clearly too fast.
    const reference = '今天天气真不错。';
    final score = await scorer.score(
      reference: reference,
      transcript: reference,
      duration: const Duration(milliseconds: 300),
    );
    expect(score.fluency, lessThan(70));
  });

  test('latin pace window is unchanged', () async {
    // 40 words in 20s = 120 wpm: inside 70-190, so no pace penalty.
    const reference =
        'one two three four five six seven eight nine ten eleven twelve '
        'thirteen fourteen fifteen sixteen seventeen eighteen nineteen '
        'twenty twenty one twenty two twenty three twenty four';
    final score = await scorer.score(
      reference: reference,
      transcript: reference,
      duration: const Duration(seconds: 20),
    );
    expect(score.fluency, greaterThanOrEqualTo(90));
  });

  test('missing words reduce accuracy and completeness', () async {
    final score = await scorer.score(
      reference: 'I would like to book a table for two',
      transcript: 'book a table',
    );
    expect(score.accuracy, lessThan(60));
    expect(score.completeness, lessThan(60));
  });

  test('empty transcript returns zeroes and actionable feedback', () async {
    final score = await scorer.score(reference: 'hello', transcript: '');
    expect(score.overall, 0);
    expect(score.feedback, isNotEmpty);
  });
}
