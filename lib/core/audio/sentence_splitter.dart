/// Splits a paragraph into playable sentences. Rules cover the languages the
/// coach already supports; the implementation deliberately errs on the side
/// of fewer, longer sentences rather than fragmenting output mid-clause.
class SentenceSplitter {
  const SentenceSplitter();

  /// Returns sentences in their original order. Empty input returns an empty
  /// list. Whitespace-only segments are dropped.
  List<String> split(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const <String>[];

    final protectedText = _protectAbbreviations(trimmed);
    final segments = _splitOnBoundaries(protectedText);
    final result = <String>[];
    for (final segment in segments) {
      var normalized = segment.trim();
      if (normalized.isEmpty) continue;

      normalized = _restoreAbbreviations(normalized);

      final merged = _reattachAbbreviations(result, normalized);
      if (merged != null) {
        result[result.length - 1] = '${result.last} $merged'.trim();
        continue;
      }
      if (normalized.length > 200) {
        result
            .addAll(_splitLongSentence(normalized).map(_restoreAbbreviations));
      } else {
        result.add(normalized);
      }
    }
    return result;
  }

  /// Swap `e.g.` / `i.e.` style abbreviations for a non-period placeholder
  /// before we scan for hard boundaries. Restored via [_restoreAbbreviations]
  /// after the split so downstream callers see the original text.
  String _protectAbbreviations(String input) {
    const patterns = <String>['e.g.', 'i.e.', 'etc.'];
    var result = input;
    for (final p in patterns) {
      result = result.replaceAll(p, p.replaceAll('.', '§'));
    }
    return result;
  }

  String _restoreAbbreviations(String input) {
    return input.replaceAll('§', '.');
  }

  List<String> _splitOnBoundaries(String input) {
    final out = <String>[];
    final buffer = StringBuffer();
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      buffer.write(ch);
      // A `.` between digits is a decimal point, not a terminator: without
      // this "Pi is 3.14." split into "Pi is 3." + "14." and each fragment
      // became its own TTS request. Same for the ellipsis run "...".
      if (_isGluedPeriod(input, i)) continue;
      final isBoundary = _isHardBoundary(ch);
      if (isBoundary && buffer.isNotEmpty) {
        out.add(buffer.toString());
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) out.add(buffer.toString());
    return out;
  }

  /// True when the `.` at [index] sits between two digits, or is part of an
  /// ellipsis run, or directly follows a single-letter initial ("A.").
  bool _isGluedPeriod(String input, int index) {
    if (input[index] != '.') return false;
    final next = index + 1 < input.length ? input[index + 1] : '';
    if (index > 0 && next.isNotEmpty && _isDigit(input[index - 1]) && _isDigit(next)) {
      return true;
    }
    if (index + 1 < input.length && input[index + 1] == '.') return true;
    if (index > 0 && _isLetter(input[index - 1]) && next.isEmpty) return true;
    return false;
  }

  bool _isDigit(String ch) => ch.codeUnitAt(0) ^ 0x30 <= 9;

  bool _isLetter(String ch) {
    final code = ch.codeUnitAt(0);
    return (code ^ 0x41 <= 25) || (code ^ 0x61 <= 25);
  }

  bool _isHardBoundary(String ch) {
    // Hard terminators — we intentionally exclude the soft comma `,` /
    // Chinese `，` / Japanese `、` because they live inside a sentence.
    return ch == '.' ||
        ch == '!' ||
        ch == '?' ||
        ch == '。' ||
        ch == '！' ||
        ch == '？' ||
        ch == ';' ||
        ch == '\n';
  }

  /// Returns true if the just-emitted segment begins with something that
  /// should join the previous sentence (e.g. `e.g.`), or the previous
  /// segment ended with a glued abbreviation that swallowed a hard period.
  String? _reattachAbbreviations(List<String> accumulator, String candidate) {
    if (accumulator.isEmpty) return null;
    final candLower = candidate.toLowerCase().trimLeft();
    final lastLower = accumulator.last.toLowerCase().trimRight();
    const gluedPrefixes = <String>[
      'e.g.',
      'i.e.',
      'etc.',
      'mr.',
      'mrs.',
      'ms.',
      'dr.',
      'st.',
      'vs.',
      'no.',
      'inc.',
      'ltd.',
      'co.',
    ];
    for (final prefix in gluedPrefixes) {
      if (candLower.startsWith(prefix)) return candidate;
    }
    for (final suffix in gluedPrefixes) {
      if (lastLower.endsWith(suffix)) return candidate;
    }
    return null;
  }

  List<String> _splitLongSentence(String sentence) {
    // Last-resort hard cut — soft chunks below 200 chars live above. Split at
    // the nearest word boundary so the TTS output doesn't break mid-word.
    const maxLen = 200;
    if (sentence.length <= maxLen) return [sentence];
    final parts = <String>[];
    var remaining = sentence;
    while (remaining.length > maxLen) {
      final chunk = remaining.substring(0, maxLen);
      final lastSpace = chunk.lastIndexOf(' ');
      if (lastSpace > maxLen ~/ 2) {
        parts.add(chunk.substring(0, lastSpace).trim());
        remaining = remaining.substring(lastSpace).trim();
      } else {
        parts.add(chunk.trim());
        remaining = remaining.substring(maxLen).trim();
      }
    }
    if (remaining.isNotEmpty) parts.add(remaining);
    return parts;
  }
}
