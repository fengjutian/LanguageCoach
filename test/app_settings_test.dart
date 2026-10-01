import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/models/app_settings.dart';

void main() {
  group('AppSettings defaults & validation', () {
    test('defaults are sane', () {
      const s = AppSettings.defaults;
      expect(s.preferredLanguage, CoachLanguage.english);
      expect(s.provider, AiProvider.auto);
      expect(s.speechSpeed, 1.0);
      expect(s.autoPlay, isFalse);
      expect(s.saveHistory, isTrue);
    });

    test('copyWith rejects unsupported speech speed', () {
      const s = AppSettings.defaults;
      expect(
        () => s.copyWith(speechSpeed: 1.42),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('copyWith accepts supported speech speed', () {
      const s = AppSettings.defaults;
      final next = s.copyWith(speechSpeed: 1.25);
      expect(next.speechSpeed, 1.25);
    });
  });

  group('AppSettings JSON', () {
    test('round-trip', () {
      const s = AppSettings(
        preferredLanguage: CoachLanguage.japanese,
        provider: AiProvider.deepSeek,
        speechSpeed: 0.85,
        autoPlay: true,
        saveHistory: false,
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.preferredLanguage, s.preferredLanguage);
      expect(back.provider, s.provider);
      expect(back.speechSpeed, s.speechSpeed);
      expect(back.autoPlay, s.autoPlay);
      expect(back.saveHistory, s.saveHistory);
    });

    test('unknown enum falls back', () {
      final s = AppSettings.fromJson(<String, Object?>{
        'preferredLanguage': 'klingon',
        'provider': 'oracle',
      });
      expect(s.preferredLanguage, CoachLanguage.english);
      expect(s.provider, AiProvider.auto);
    });

    test('out-of-range speech speed clamped to 1.0', () {
      final s = AppSettings.fromJson(<String, Object?>{'speechSpeed': 2.7});
      expect(s.speechSpeed, 1.0);
    });

    test('numeric speech speed as string is parsed', () {
      final s = AppSettings.fromJson(<String, Object?>{'speechSpeed': '1.25'});
      expect(s.speechSpeed, 1.25);
    });

    test('missing booleans default sensibly', () {
      final s = AppSettings.fromJson(<String, Object?>{});
      expect(s.autoPlay, isFalse);
      expect(s.saveHistory, isTrue);
    });
  });
}