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
