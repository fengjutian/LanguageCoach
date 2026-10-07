import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/core/audio/model_download_service.dart';
import 'package:language_coach/core/audio/model_manager.dart';
import 'package:language_coach/core/audio/model_manifest.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/chat/application/chat_controller.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';
import 'package:language_coach/features/chat/chat_page.dart';
import 'package:language_coach/features/history/history_page.dart';
import 'package:language_coach/features/home/application/home_navigation.dart';
import 'package:language_coach/features/home/home_page.dart';
import 'package:language_coach/features/settings/application/model_controller.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';

/// Answers immediately with a fixed reply — widget tests care about the UI
/// transitions, not about stream timing.
class _InstantProvider implements LlmProvider {
  _InstantProvider({this.primary = 'It is raining today.'});

  final String primary;
  final List<CoachRequest> requests = <CoachRequest>[];

  @override
  String get id => 'instant';

  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) async* {
    requests.add(request);
    yield LlmEventDelta(primary);
    final response = CoachResponse(
      intent: request.intent,
      sourceLanguage: 'auto',
      targetLanguage: request.targetLanguage.code,
      primary: primary,
      explanation: '因为',
      sentences: <CoachSentence>[CoachSentence(id: 's1', text: primary)],
    );
    yield LlmEventComplete(
      response,
      ChatMessage(
        id: 'm_${requests.length}',
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: response,
        model: id,
        status: ChatMessageStatus.completed,
      ),
    );
  }
}

class _EmptyModelService extends ModelDownloadService {
  _EmptyModelService({required super.rootDirectory, required super.events});

  @override
  ModelManifest? manifestFor(String modelId) => null;
}

Widget _wrapChat({
  required InMemoryConversationRepository repository,
  required _InstantProvider provider,
  required Directory tmp,
  AppSettings? settings,
}) {
  return ProviderScope(
    overrides: [
      conversationRepositoryProvider.overrideWithValue(repository),
      settingsRepositoryProvider
          .overrideWithValue(InMemorySettingsRepository()),
      settingsControllerProvider.overrideWith(
        () => _Seeded(settings ?? AppSettings.defaults),
      ),
      llmRouterProvider.overrideWithValue(
        LlmRouter(
          manualMiniMax: provider,
          manualDeepSeek: provider,
          localQwen: provider,
        ),
      ),
      audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
      ttsOutputDirectoryProvider.overrideWithValue(tmp),
      modelDownloadServiceProvider.overrideWithValue(
        _EmptyModelService(rootDirectory: tmp, events: _events()),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: ChatPage())),
  );
}

StreamController<ModelEvent> _events() =>
    StreamController<ModelEvent>.broadcast();

class _Seeded extends SettingsController {
  _Seeded(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() => _initial;
}

Future<void> _seedConversation(
  InMemoryConversationRepository repo,
  String id, {
  String userText = '你好',
  String answer = 'こんにちは',
  CoachLanguage language = CoachLanguage.japanese,
}) async {
  await repo.ensureConversation(
    id,
    title: 'seed $id',
    preferredLanguage: CoachLanguage.english,
    targetLanguage: language,
  );
  await repo.appendMessage(
    conversationId: id,
    message: ChatMessage(
      id: 'u_$id',
      role: MessageRole.user,
      createdAt: DateTime(2026),
      sourceText: userText,
    ),
  );
  await repo.appendMessage(
    conversationId: id,
    message: ChatMessage(
      id: 'a_$id',
      role: MessageRole.assistant,
      createdAt: DateTime(2026, 1, 1, 0, 0, 1),
      response: CoachResponse(
        intent: CoachIntent.conversation,
        sourceLanguage: 'auto',
        targetLanguage: language.code,
        primary: answer,
        explanation: '',
        sentences: <CoachSentence>[CoachSentence(id: 's', text: answer)],
      ),
    ),
  );
}

ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(ChatPage)));

/// Let a send finish.
///
/// Deliberately not `pumpAndSettle`: while a reply streams, the page shows an
/// indeterminate progress indicator, so "no frames scheduled" is not a state
/// this UI ever reaches on its own. Fixed pumps are what a real frame budget
/// looks like and let assertions run against a settled transcript.
Future<void> _settleSend(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('new conversation empties the transcript immediately',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    final provider = _InstantProvider();
    await _seedConversation(repo, 'c1');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: provider,
      tmp: tmp,
      settings: AppSettings.defaults.copyWith(lastConversationId: 'c1'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('你好'), findsOneWidget);

    final container = _containerOf(tester);
    await container.read(chatControllerProvider.notifier).newConversation();
    await tester.pumpAndSettle();

    expect(find.text('你好'), findsNothing);
    expect(find.text('今天想练习什么？'), findsOneWidget);
  });

  testWidgets('opening two conversations in a row shows each transcript',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await _seedConversation(repo, 'cA', userText: 'first question');
    await _seedConversation(repo, 'cB', userText: 'second question');
    await tester.pumpWidget(
        _wrapChat(repository: repo, provider: _InstantProvider(), tmp: tmp));
    await tester.pumpAndSettle();

    final controller =
        _containerOf(tester).read(chatControllerProvider.notifier);
    await controller.openConversation('cA');
    await tester.pumpAndSettle();
    expect(find.text('first question'), findsOneWidget);
    expect(find.text('second question'), findsNothing);

    await controller.openConversation('cB');
    await tester.pumpAndSettle();
    expect(find.text('second question'), findsOneWidget);
    expect(find.text('first question'), findsNothing);
  });

  testWidgets('sending over the length cap leaves the composer unusable',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await tester.pumpWidget(
        _wrapChat(repository: repo, provider: _InstantProvider(), tmp: tmp));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'x' * (kMaxUserMessageLength + 10),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('上限'), findsWidgets);

    // The controller refuses it too, so a programmatic send cannot slip past.
    final container = _containerOf(tester);
    await container
        .read(chatControllerProvider.notifier)
        .send('x' * (kMaxUserMessageLength + 10));
    await tester.pumpAndSettle();
    expect(container.read(chatControllerProvider).messages, isEmpty);
  });

  testWidgets('switching the conversation language changes the request',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    final provider = _InstantProvider(primary: '今日は雨です');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: provider,
      tmp: tmp,
      settings: AppSettings.defaults.copyWith(
        preferredLanguage: CoachLanguage.japanese,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '今天下雨吗');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settleSend(tester);

    expect(provider.requests.single.targetLanguage, CoachLanguage.japanese);
    // The answer shows up both as the bubble headline and as its sentence
    // tile, so this asserts presence rather than an exact count.
    expect(find.text('今日は雨です'), findsWidgets);
  });

  testWidgets('history page resumes a conversation and switches to Chat tab',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await _seedConversation(repo, 'c1', userText: 'history question');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationRepositoryProvider.overrideWithValue(repo),
          settingsRepositoryProvider
              .overrideWithValue(InMemorySettingsRepository()),
          audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
          ttsOutputDirectoryProvider.overrideWithValue(tmp),
          modelDownloadServiceProvider.overrideWithValue(
            _EmptyModelService(rootDirectory: tmp, events: _events()),
          ),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    // Scope the finder to the History tab. The chat drawer renders the same
    // titles offstage, and an unscoped finder happily taps the hidden copy.
    await tester.tap(find.descendant(
      of: find.byType(HistoryPage),
      matching: find.textContaining('seed c1'),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final container =
        ProviderScope.containerOf(tester.element(find.byType(ChatPage)));
    // Home switched to the Chat tab and the transcript is actually loaded.
    expect(container.read(homeTabProvider), HomeTab.chat);
    expect(container.read(chatControllerProvider).conversationId, 'c1');
    expect(
      find.descendant(
        of: find.byType(ChatPage),
        matching: find.text('history question'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a deleted conversation is not revived by the next send',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await _seedConversation(repo, 'c1');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: _InstantProvider(),
      tmp: tmp,
      settings: AppSettings.defaults.copyWith(lastConversationId: 'c1'),
    ));
    await tester.pumpAndSettle();

    final container = _containerOf(tester);
    expect(find.text('你好'), findsOneWidget);

    await repo.deleteConversation('c1');
    await container
        .read(chatControllerProvider.notifier)
        .handleConversationDeleted('c1');
    await tester.pumpAndSettle();
    expect(find.text('你好'), findsNothing);

    await tester.enterText(find.byType(TextField), 'brand new question');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settleSend(tester);

    expect(await repo.getConversation('c1'), isNull);
    expect(find.text('brand new question'), findsOneWidget);
  });

  testWidgets('new conversation shows the empty state while messages persist',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: _InstantProvider(),
      tmp: tmp,
      settings: AppSettings.defaults.copyWith(lastConversationId: 'c1'),
    ));
    await tester.pumpAndSettle();
    final container = _containerOf(tester);

    await container.read(chatControllerProvider.notifier).newConversation();
    await tester.pumpAndSettle();
    expect(find.text('今天想练习什么？'), findsOneWidget);
    // A draft must not create a row yet.
    final state = container.read(chatControllerProvider);
    expect(state.isDraft, isTrue);
    expect(await repo.recentConversations(), isEmpty);

    // Reopening the deleted-from-memory id is a no-op, the draft survives.
    await container.read(chatControllerProvider.notifier).initialize();
    await tester.pumpAndSettle();
  });

  testWidgets('opening a missing conversation shows a recoverable notice',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: _InstantProvider(),
      tmp: tmp,
      settings: AppSettings.defaults.copyWith(lastConversationId: 'ghost'),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('已不存在'), findsOneWidget);
    expect(find.text('今天想练习什么？'), findsOneWidget);
  });

  testWidgets(
      'a Japanese conversation restored from history keeps its language',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await _seedConversation(
      repo,
      'c1',
      userText: 'こんにちは',
      answer: '雪が降っています',
      language: CoachLanguage.japanese,
    );
    final provider = _InstantProvider(primary: 'また明日');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: provider,
      tmp: tmp,
      // Global default is English; the conversation is Japanese.
      settings: AppSettings.defaults.copyWith(lastConversationId: 'c1'),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '明日は？');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settleSend(tester);

    expect(provider.requests.single.targetLanguage, CoachLanguage.japanese);
  });

  testWidgets('explicit English request overrides a Japanese conversation',
      (tester) async {
    final repo = InMemoryConversationRepository();
    final tmp = Directory.systemTemp.createTempSync('chat_widget_');
    await _seedConversation(repo, 'c1', language: CoachLanguage.japanese);
    final provider = _InstantProvider(primary: 'It is snowing.');
    await tester.pumpWidget(_wrapChat(
      repository: repo,
      provider: provider,
      tmp: tmp,
      settings: AppSettings.defaults.copyWith(lastConversationId: 'c1'),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '用英语怎么说"雪"');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settleSend(tester);

    expect(provider.requests.single.targetLanguage, CoachLanguage.english);
    // The UI states the language actually used for this turn.
    expect(find.textContaining('本轮已按你的要求'), findsOneWidget);
  });
}
