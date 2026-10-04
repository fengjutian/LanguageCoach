class PronunciationScore {
  const PronunciationScore({
    required this.phoneme,
    required this.accuracy,
    required this.fluency,
    required this.completeness,
    required this.feedback,
  });

  final int phoneme;
  final int accuracy;
  final int fluency;
  final int completeness;
  final List<String> feedback;

  int get overall =>
      ((phoneme + accuracy + fluency + completeness) / 4).round();
}

abstract interface class PronunciationScorer {
  Future<PronunciationScore> score({
    required String reference,
    required String transcript,
    Duration? duration,
  });
}

/// Offline fallback based on ASR text alignment. This is deliberately behind
/// an interface so a phoneme-alignment service can replace it without changing
/// the training flow or stored score shape.
class TranscriptPronunciationScorer implements PronunciationScorer {
  const TranscriptPronunciationScorer();

  @override
  Future<PronunciationScore> score({
    required String reference,
    required String transcript,
    Duration? duration,
  }) async {
    final expected = _tokens(reference);
    final actual = _tokens(transcript);
    if (expected.isEmpty || actual.isEmpty) {
      return const PronunciationScore(
        phoneme: 0,
        accuracy: 0,
        fluency: 0,
        completeness: 0,
        feedback: ['没有识别到有效语音，请靠近麦克风后重试。'],
      );
    }

    final distance = _editDistance(expected, actual);
    final accuracy = _clamp(100 - distance * 100 ~/ expected.length);
    final matched = (expected.length - distance).clamp(0, expected.length);
    final completeness = _clamp(matched * 100 ~/ expected.length);
    final lengthRatio = actual.length / expected.length;
    final phoneme = _clamp((accuracy * .75 + completeness * .25).round());

    var fluency = _clamp((100 - (lengthRatio - 1).abs() * 45).round());
    if (duration != null && duration.inMilliseconds > 0) {
      final wordsPerMinute = actual.length * 60000 / duration.inMilliseconds;
      final pacePenalty = wordsPerMinute < 70
          ? (70 - wordsPerMinute) * .5
          : wordsPerMinute > 190
              ? (wordsPerMinute - 190) * .35
              : 0;
      fluency = _clamp(fluency - pacePenalty.round());
    }

    final feedback = <String>[];
    if (accuracy < 75) feedback.add('放慢速度，先逐词对照原句。');
    if (completeness < 85) feedback.add('有内容遗漏，请完整读到句末。');
    if (fluency < 75) feedback.add('注意连贯表达，减少停顿或抢读。');
    if (feedback.isEmpty) feedback.add('完成得很好，可以尝试更自然的语调。');

    return PronunciationScore(
      phoneme: phoneme,
      accuracy: accuracy,
      fluency: fluency,
      completeness: completeness,
      feedback: feedback,
    );
  }

  static List<String> _tokens(String value) {
    final normalized = value
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9\u3400-\u9fff\u3040-\u30ff\uac00-\ud7af\s']"), ' ')
        .trim();
    if (normalized.isEmpty) return const [];
    if (RegExp(r'[\u3400-\u9fff\u3040-\u30ff]').hasMatch(normalized)) {
      return normalized.replaceAll(RegExp(r'\s+'), '').split('');
    }
    return normalized.split(RegExp(r'\s+'));
  }

  static int _editDistance(List<String> a, List<String> b) {
    var previous = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 0; i < a.length; i++) {
      final current = List<int>.filled(b.length + 1, 0)..[0] = i + 1;
      for (var j = 0; j < b.length; j++) {
        current[j + 1] = a[i] == b[j]
            ? previous[j]
            : 1 + [previous[j], previous[j + 1], current[j]].reduce(
                (x, y) => x < y ? x : y,
              );
      }
      previous = current;
    }
    return previous.last;
  }

  static int _clamp(int value) => value.clamp(0, 100);
}
