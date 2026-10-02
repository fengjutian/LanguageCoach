import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/home/home_page.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';
import 'package:language_coach/features/settings/settings_page.dart';

Widget _wrap(Widget child) => ProviderScope(
      overrides: [
        settingsRepositoryProvider
            .overrideWithValue(InMemorySettingsRepository()),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

ProviderContainer _containerFor(WidgetTester tester, Finder finder) =>
    ProviderScope.containerOf(tester.element(finder));

void main() {
  testWidgets('SettingsPage renders and reflects defaults', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(_wrap(const SettingsPage()));
    expect(find.text('设置'), findsAtLeastNWidgets(1));
    expect(find.text('首选语言'), findsOneWidget);
    expect(find.text('Provider'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsAtLeastNWidgets(2));
    expect(find.text('API Keys'), findsOneWidget);
  });

  testWidgets('Settings controller propagates to settings page',
      (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));
    final container = _containerFor(tester, find.byType(SettingsPage));
    container.read(settingsControllerProvider.notifier)
      ..setPreferredLanguage(CoachLanguage.japanese)
      ..setSpeechSpeed(1.25);
    await tester.pumpAndSettle();
    final value = container.read(settingsControllerProvider);
    expect(value.preferredLanguage, CoachLanguage.japanese);
    expect(value.speechSpeed, 1.25);
  });

  testWidgets('HomePage mounts Chat, History, Settings tabs', (tester) async {
    final settings = InMemorySettingsRepository();
    final conversations = InMemoryConversationRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          conversationRepositoryProvider.overrideWithValue(conversations),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
