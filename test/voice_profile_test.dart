import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/voice_profile.dart';
import 'package:language_coach/core/models/app_settings.dart';

void main() {
  group('VoiceProfile catalog', () {
    test('every supported language has at least one voice', () {
      for (final lang in CoachLanguage.values) {
        expect(
          voicesFor(lang),
          isNotEmpty,
          reason: 'no voice profile registered for $lang',
        );
      }
    });

    test('default voice for a language exists in the catalog', () {
      final fallback = defaultVoiceFor(CoachLanguage.english);
      expect(fallback.id, isNotEmpty);
      expect(voiceById(fallback.id), isNotNull);
    });

    test('voicesFor sorts the language neutral default first', () {
      final voices = voicesFor(CoachLanguage.english);
      expect(voices.first.id, endsWith('_neutral'));
    });
  });

  group('AppSettings voice selection', () {
    test('voiceFor falls back to the supplied default when no pick exists', () {
      const settings = AppSettings(
        preferredLanguage: CoachLanguage.english,
        provider: AiProvider.auto,
        speechSpeed: 1.0,
        autoPlay: false,
        saveHistory: true,
      );
      expect(settings.voiceFor(CoachLanguage.english, 'en_us_neutral'),
          'en_us_neutral');
    });

    test('voiceFor returns the per-language pick when one is set', () {
      final settings = const AppSettings(
        preferredLanguage: CoachLanguage.english,
        provider: AiProvider.auto,
        speechSpeed: 1.0,
        autoPlay: false,
        saveHistory: true,
      ).copyWith(
        selectedVoices: const {CoachLanguage.english: 'en_us_female_warm'},
      );
      expect(settings.voiceFor(CoachLanguage.english, 'en_us_neutral'),
          'en_us_female_warm');
    });

    test('JSON round-trip preserves selected voices', () {
      final settings = const AppSettings(
        preferredLanguage: CoachLanguage.english,
        provider: AiProvider.auto,
        speechSpeed: 1.0,
        autoPlay: false,
        saveHistory: true,
      ).copyWith(
        selectedVoices: const {CoachLanguage.japanese: 'ja_jp_neutral'},
      );
      final round = AppSettings.fromJson(settings.toJson());
      expect(round.selectedVoices[CoachLanguage.japanese], 'ja_jp_neutral');
    });

    test('unknown JSON language keys are ignored', () {
      final settings = AppSettings.fromJson({
        ...AppSettings.defaults.toJson(),
        'selectedVoices': const {
          'futureLanguage': 'unknown_voice',
          'japanese': 'ja_jp_neutral',
        },
      });

      expect(settings.selectedVoices, const {
        CoachLanguage.japanese: 'ja_jp_neutral',
      });
      expect(settings.selectedVoices[CoachLanguage.english], isNull);
    });
  });
}
