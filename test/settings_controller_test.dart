import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';

ProviderContainer _containerWithInMemoryRepo() {
  final repo = InMemorySettingsRepository();
  return ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(repo),
    ],
  );
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = _containerWithInMemoryRepo();
  });

  tearDown(() {
    container.dispose();
  });

  test('starts at defaults', () {
    final s = container.read(settingsControllerProvider);
    expect(s, AppSettings.defaults);
  });

  test('notifier updates emit new immutable state', () async {
    final notifier = container.read(settingsControllerProvider.notifier);
    notifier.setPreferredLanguage(CoachLanguage.french);
    notifier.setProvider(AiProvider.deepSeek);
    notifier.setSpeechSpeed(0.85);
    notifier.setAutoPlay(true);
    notifier.setSaveHistory(false);
    // Allow the unawaited persist microtasks to drain.
    await Future<void>.delayed(Duration.zero);
    final s = container.read(settingsControllerProvider);
    expect(s.preferredLanguage, CoachLanguage.french);
    expect(s.provider, AiProvider.deepSeek);
    expect(s.speechSpeed, 0.85);
    expect(s.autoPlay, isTrue);
    expect(s.saveHistory, isFalse);
  });

  test('replace() swaps state wholesale and persists', () async {
    container.read(settingsControllerProvider.notifier).replace(
          const AppSettings(
            preferredLanguage: CoachLanguage.german,
            provider: AiProvider.localQwen,
            speechSpeed: 1.5,
            autoPlay: true,
            saveHistory: true,
          ),
        );
    await Future<void>.delayed(Duration.zero);
    final s = container.read(settingsControllerProvider);
    expect(s.preferredLanguage, CoachLanguage.german);
    expect(s.speechSpeed, 1.5);
  });

  test('hydrateFromJson keeps defensive defaults', () async {
    await container
        .read(settingsControllerProvider.notifier)
        .hydrateFromJson(<String, Object?>{'preferredLanguage': 'klingon'});
    final s = container.read(settingsControllerProvider);
    expect(s.preferredLanguage, CoachLanguage.english);
  });

  test('lastConversationId round-trips', () async {
    final notifier = container.read(settingsControllerProvider.notifier);
    notifier.setLastConversationId('c_123');
    await Future<void>.delayed(Duration.zero);
    expect(
        container.read(settingsControllerProvider).lastConversationId, 'c_123');
    notifier.setLastConversationId(null);
    await Future<void>.delayed(Duration.zero);
    expect(
        container.read(settingsControllerProvider).lastConversationId, isNull);
  });
}
