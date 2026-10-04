import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/core/audio/model_download_service.dart';
import 'package:language_coach/core/audio/model_manager.dart';
import 'package:language_coach/core/audio/model_manifest.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';
import 'package:language_coach/features/home/home_page.dart';
import 'package:language_coach/features/practice/practice_page.dart';
import 'package:language_coach/features/practice/repeat_practice_page.dart';
import 'package:language_coach/features/practice/roleplay_page.dart';
import 'package:language_coach/features/practice/shadowing_page.dart';
import 'package:language_coach/features/settings/application/model_controller.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';
import 'package:language_coach/features/settings/settings_page.dart';

/// Test double for the model download service. Has no in-flight manifests
/// so widget tests never trigger a download.
class _EmptyModelService extends ModelDownloadService {
  _EmptyModelService({required super.rootDirectory, required super.events});

  @override
  ModelManifest? manifestFor(String modelId) => null;
}

StreamController<ModelEvent> _newEvents() {
  final controller = StreamController<ModelEvent>.broadcast();
  addTearDown(controller.close);
  return controller;
}

Widget _wrap(Widget child, {Directory? tmp}) {
  final root = tmp ?? Directory.systemTemp.createTempSync('widget_test_root_');
  return ProviderScope(
    overrides: [
      settingsRepositoryProvider
          .overrideWithValue(InMemorySettingsRepository()),
      modelDownloadServiceProvider.overrideWithValue(
        _EmptyModelService(rootDirectory: root, events: _newEvents()),
      ),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

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
    // SliverAppBar.large keeps both the collapsed and expanded title widgets
    // in the tree simultaneously, so an exact '设置' Text appears twice
    // (the bar's auto-sized variants). Use `findsWidgets` for the page
    // title to match the framework reality.
    expect(find.text('设置'), findsWidgets);
    expect(find.text('常规设置'), findsOneWidget);
    expect(find.text('AI 服务'), findsOneWidget);
    expect(find.text('语音设置'), findsOneWidget);
    expect(find.text('模型与工具'), findsOneWidget);
    expect(find.text('首选语言'), findsNothing);
  });

  testWidgets('SettingsPage opens settings sections as second-level pages',
      (tester) async {
    await tester.pumpWidget(_wrap(const SettingsPage()));

    await tester.tap(find.text('常规设置'));
    await tester.pumpAndSettle();
    expect(find.text('首选语言'), findsOneWidget);
    expect(find.text('保存聊天记录'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('AI 服务'));
    await tester.pumpAndSettle();
    expect(find.text('Provider'), findsOneWidget);
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

  testWidgets('HomePage mounts Chat, Practice, History, Settings tabs',
      (tester) async {
    final settings = InMemorySettingsRepository();
    final conversations = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('home_test_root_');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          conversationRepositoryProvider.overrideWithValue(conversations),
          audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
          ttsOutputDirectoryProvider.overrideWithValue(tmp),
          modelDownloadServiceProvider.overrideWithValue(
            _EmptyModelService(rootDirectory: tmp, events: _newEvents()),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('练习'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('Practice entry opens the dedicated repeat flow', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('practice_test_root_');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider
              .overrideWithValue(InMemorySettingsRepository()),
          conversationRepositoryProvider
              .overrideWithValue(InMemoryConversationRepository()),
          audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
          ttsOutputDirectoryProvider.overrideWithValue(tmp),
          modelDownloadServiceProvider.overrideWithValue(
            _EmptyModelService(rootDirectory: tmp, events: _newEvents()),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );

    await tester.tap(find.text('练习'));
    await tester.pumpAndSettle();
    expect(find.byType(PracticePage), findsOneWidget);
    expect(find.text('跟读练习'), findsOneWidget);

    await tester.tap(find.text('开始跟读'));
    await tester.pumpAndSettle();
    expect(find.byType(RepeatPracticePage), findsOneWidget);
    expect(find.text('1. 播放原句'), findsOneWidget);
    expect(find.text('2. 开始跟读'), findsOneWidget);
    expect(find.text('音素'), findsNothing);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -260));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始影子训练'));
    await tester.pumpAndSettle();
    expect(find.byType(ShadowingPage), findsOneWidget);
    expect(find.text('0.75×'), findsOneWidget);
    expect(find.text('不循环 · 1.0×'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).last, const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择场景'));
    await tester.pumpAndSettle();
    expect(find.byType(RoleplayPage), findsOneWidget);
    expect(find.text('酒店入住'), findsWidgets);
    expect(find.text('进入场景'), findsOneWidget);
  });
}
