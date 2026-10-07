import '../models/app_settings.dart';

/// Resolves the language a turn should be answered in.
///
/// Priority (product rule, do not reorder):
///   1. the learner's text explicitly names a language,
///   2. the conversation's current target language,
///   3. English as the global fallback.
///
/// [resolveExplicit] implements step 1 and returns `null` when the text names
/// no language, which is the signal for the caller to fall through to the
/// conversation language.
class TargetLanguageResolver {
  static const _aliases = <CoachLanguage, List<String>>{
    CoachLanguage.english: ['英语', '英文', 'english'],
    CoachLanguage.japanese: ['日语', '日文', 'japanese', '日本語'],
    CoachLanguage.french: ['法语', 'french', 'français'],
    CoachLanguage.korean: ['韩语', '韩国语', 'korean', '한국어'],
    CoachLanguage.spanish: ['西班牙语', 'spanish', 'español'],
    CoachLanguage.german: ['德语', 'german', 'deutsch'],
    CoachLanguage.italian: ['意大利语', 'italian', 'italiano'],
    CoachLanguage.chinese: ['中文', '汉语', 'chinese'],
    CoachLanguage.russian: ['俄语', 'russian'],
    CoachLanguage.portuguese: ['葡萄牙语', 'portuguese'],
  };

  /// Longest alias first. "韩语" and "韩" style prefixes must not win over
  /// "韩国语", and "西班牙语" must not lose to a bare "语" substring — the
  /// scan walks every alias and keeps the longest hit, so ordering inside the
  /// map never decides the result.
  static List<(CoachLanguage, String)> get _scannable {
    final list = <(CoachLanguage, String)>[];
    for (final entry in _aliases.entries) {
      for (final alias in entry.value) {
        list.add((entry.key, alias.toLowerCase()));
      }
    }
    list.sort((a, b) => b.$2.length.compareTo(a.$2.length));
    return list;
  }

  /// The language explicitly named by [input], or `null`.
  CoachLanguage? resolveExplicit(String input) {
    final normalized = input.toLowerCase();
    CoachLanguage? best;
    var bestLength = 0;
    for (final (language, alias) in _scannable) {
      if (alias.length <= bestLength) continue;
      if (normalized.contains(alias)) {
        best = language;
        bestLength = alias.length;
      }
    }
    return best;
  }

  /// Convenience wrapper kept for callers that still have a single fallback
  /// language in hand (settings default). Prefer [resolveExplicit] plus the
  /// caller's own fallback chain.
  CoachLanguage resolve(String input, CoachLanguage preferred) {
    return resolveExplicit(input) ?? preferred;
  }
}
