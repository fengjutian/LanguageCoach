import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/practice_repository.dart';
import '../domain/pronunciation_score.dart';

final pronunciationScorerProvider = Provider<PronunciationScorer>(
  (_) => const TranscriptPronunciationScorer(),
);

final practiceRepositoryProvider = Provider<PracticeRepository>(
  (_) => InMemoryPracticeRepository(),
);

final practiceAttemptsProvider =
    AsyncNotifierProvider<PracticeAttemptsController, List<PracticeAttempt>>(
  PracticeAttemptsController.new,
);

class PracticeAttemptsController extends AsyncNotifier<List<PracticeAttempt>> {
  @override
  Future<List<PracticeAttempt>> build() {
    return ref.watch(practiceRepositoryProvider).list();
  }

  Future<void> add(PracticeAttempt attempt) async {
    await ref.read(practiceRepositoryProvider).save(attempt);
    state = AsyncData(await ref.read(practiceRepositoryProvider).list());
  }
}
