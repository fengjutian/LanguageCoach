import '../models/app_settings.dart';

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

  CoachLanguage resolve(String input, CoachLanguage preferred) {
    final normalized = input.toLowerCase();
    for (final entry in _aliases.entries) {
      if (entry.value.any(normalized.contains)) return entry.key;
    }
    return preferred;
  }
}
