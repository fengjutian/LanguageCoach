import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../domain/pronunciation_score.dart';

class PracticeAttempt {
  const PracticeAttempt({
    required this.id,
    required this.language,
    required this.referenceText,
    required this.transcript,
    required this.score,
    required this.createdAt,
    this.duration,
  });

  final String id;
  final String language;
  final String referenceText;
  final String transcript;
  final PronunciationScore score;
  final DateTime createdAt;
  final Duration? duration;
}

abstract interface class PracticeRepository {
  Future<void> save(PracticeAttempt attempt);
  Future<List<PracticeAttempt>> list({int limit = 100});
}

class InMemoryPracticeRepository implements PracticeRepository {
  final List<PracticeAttempt> _items = [];

  @override
  Future<List<PracticeAttempt>> list({int limit = 100}) async =>
      _items.take(limit).toList(growable: false);

  @override
  Future<void> save(PracticeAttempt attempt) async {
    _items.insert(0, attempt);
  }
}

class SqlitePracticeRepository implements PracticeRepository {
  const SqlitePracticeRepository(this.database);
  final AppDatabase database;

  @override
  Future<void> save(PracticeAttempt attempt) async {
    await database.db.insert('practice_attempts', {
      'id': attempt.id,
      'mode': 'repeat',
      'language': attempt.language,
      'reference_text': attempt.referenceText,
      'transcript': attempt.transcript,
      'overall_score': attempt.score.overall,
      'phoneme_score': attempt.score.phoneme,
      'accuracy_score': attempt.score.accuracy,
      'fluency_score': attempt.score.fluency,
      'completeness_score': attempt.score.completeness,
      'duration_ms': attempt.duration?.inMilliseconds,
      'created_at': attempt.createdAt.millisecondsSinceEpoch,
    });
  }

  @override
  Future<List<PracticeAttempt>> list({int limit = 100}) async {
    final rows = await database.db.query(
      'practice_attempts',
      orderBy: 'created_at DESC',
      limit: limit,
    );
    return rows.map((row) {
      return PracticeAttempt(
        id: row['id'] as String,
        language: row['language'] as String,
        referenceText: row['reference_text'] as String,
        transcript: row['transcript'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        duration: row['duration_ms'] == null
            ? null
            : Duration(milliseconds: row['duration_ms'] as int),
        score: PronunciationScore(
          phoneme: row['phoneme_score'] as int,
          accuracy: row['accuracy_score'] as int,
          fluency: row['fluency_score'] as int,
          completeness: row['completeness_score'] as int,
          feedback: const [],
        ),
      );
    }).toList(growable: false);
  }
}

PracticeAttempt newPracticeAttempt({
  required String language,
  required String referenceText,
  required String transcript,
  required PronunciationScore score,
  required Duration duration,
}) =>
    PracticeAttempt(
      id: const Uuid().v4(),
      language: language,
      referenceText: referenceText,
      transcript: transcript,
      score: score,
      createdAt: DateTime.now(),
      duration: duration,
    );
