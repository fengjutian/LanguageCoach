import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/features/home/home_page.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';
import 'package:language_coach/features/settings/settings_page.dart';

/// Pages that render `ListTile` / `SwitchListTile` directly need a
/// [Scaffold] ancestor (otherwise `debugCheckHasMaterial` fires in test).
Widget _wrap(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: child)),
    );

ProviderContainer _containerFor(WidgetTester tester, Finder finder) =>
    ProviderScope.containerOf(tester.element(finder));

void main() {
  testWidgets('SettingsPage renders and reflects defaults', (tester) async {
    // Use a tall viewport so all SliverList children can be measured in a
    // single frame — the layout uses SliverAppBar.large which otherwise
    // claims most of the default 600px viewport.
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
    await tester.pump();
    final value = container.read(settingsControllerProvider);
    expect(value.preferredLanguage, CoachLanguage.japanese);
    expect(value.speechSpeed, 1.25);
  });

  testWidgets('HomePage mounts Chat, History, Settings tabs', (tester) async {
    // HomePage ships its own Scaffold + NavigationBar, so no extra body wrap.
    await tester
        .pumpWidget(ProviderScope(child: MaterialApp(home: const HomePage())));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('设置'), findsAtLeastNWidgets(1));
  });
}
