import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer();
  });

  tearDown(() {
    container.dispose();
  });

  test('starts at defaults', () {
    final s = container.read(settingsControllerProvider);
    expect(s, AppSettings.defaults);
  });

  test('notifier updates emit new immutable state', () {
    final notifier = container.read(settingsControllerProvider.notifier);
    notifier.setPreferredLanguage(CoachLanguage.french);
    notifier.setProvider(AiProvider.deepSeek);
    notifier.setSpeechSpeed(0.85);
    notifier.setAutoPlay(true);
    notifier.setSaveHistory(false);

    final after = container.read(settingsControllerProvider);
    expect(after.preferredLanguage, CoachLanguage.french);
    expect(after.provider, AiProvider.deepSeek);
    expect(after.speechSpeed, 0.85);
    expect(after.autoPlay, isTrue);
    expect(after.saveHistory, isFalse);
  });

  test('replace() swaps state wholesale (P0-3 persistence entry)', () {
    container.read(settingsControllerProvider.notifier).replace(
          const AppSettings(
            preferredLanguage: CoachLanguage.german,
            provider: AiProvider.localQwen,
            speechSpeed: 1.5,
            autoPlay: true,
            saveHistory: true,
          ),
        );
    final s = container.read(settingsControllerProvider);
    expect(s.preferredLanguage, CoachLanguage.german);
    expect(s.speechSpeed, 1.5);
  });

  test('hydrateFromJson keeps defensive defaults', () {
    container.read(settingsControllerProvider.notifier).hydrateFromJson(
      <String, Object?>{'preferredLanguage': 'klingon'},
    );
    final s = container.read(settingsControllerProvider);
    expect(s.preferredLanguage, CoachLanguage.english);
  });
}
