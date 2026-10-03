import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/core/audio/fake_tts_engine.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/repositories/in_memory_repositories.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';
import 'package:language_coach/features/chat/widgets/message_bubble.dart';

Widget _wrap(Widget child) => ProviderScope(
      overrides: [
        settingsRepositoryProvider
            .overrideWithValue(InMemorySettingsRepository()),
        conversationRepositoryProvider
            .overrideWithValue(InMemoryConversationRepository()),
        audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
        ttsOutputDirectoryProvider.overrideWithValue(
            Directory.systemTemp.createTempSync('tts_test_')),
        ttsEngineProvider.overrideWith(
          (ref) => FakeTtsEngine(
              outputDirectory: ref.watch(ttsOutputDirectoryProvider)),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: child)),
    );

ChatMessage _sampleMessage() => ChatMessage(
      id: 'msg1',
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      response: CoachResponse(
        intent: CoachIntent.conversation,
        sourceLanguage: 'zh-CN',
        targetLanguage: 'en',
        primary: 'It is raining today.',
        explanation: 'simple present progressive',
        sentences: const [
          CoachSentence(id: 's_msg1_0', text: 'It is raining.'),
          CoachSentence(id: 's_msg1_1', text: 'Today is grey.'),
        ],
      ),
      model: 'MiniMax (Demo)',
    );

void main() {
  testWidgets('Chinese input and English answer are labelled and readable',
      (tester) async {
    final userMessage = ChatMessage(
      id: 'user1',
      role: MessageRole.user,
      createdAt: DateTime(2026),
      sourceText: '南京的盐水鸭非常有名。',
    );

    await tester.pumpWidget(_wrap(
      ListView(
        children: [
          MessageBubble(message: userMessage, conversationId: 'c1'),
          MessageBubble(message: _sampleMessage(), conversationId: 'c1'),
        ],
      ),
    ));

    expect(find.text('中文原文'), findsOneWidget);
    expect(find.text('南京的盐水鸭非常有名。'), findsOneWidget);
    expect(find.byTooltip('朗读中文原文'), findsOneWidget);
    expect(find.text('英文表达'), findsOneWidget);
    expect(find.text('It is raining today.'), findsOneWidget);
    expect(find.byTooltip('播放整段'), findsOneWidget);
  });

  testWidgets('renders assistant bubble with sentences and play buttons',
      (tester) async {
    await tester.pumpWidget(_wrap(
      MessageBubble(message: _sampleMessage(), conversationId: 'c1'),
    ));
    expect(find.text('It is raining today.'), findsOneWidget);
    expect(find.text('It is raining.'), findsOneWidget);
    expect(find.text('Today is grey.'), findsOneWidget);
    expect(find.text('逐句 1'), findsOneWidget);
    expect(find.text('逐句 2'), findsOneWidget);
  });

  testWidgets('tapping whole-message play updates TtsPlaybackState',
      (tester) async {
    await tester.pumpWidget(_wrap(
      MessageBubble(message: _sampleMessage(), conversationId: 'c1'),
    ));

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageBubble)),
    );

    expect(container.read(ttsControllerProvider).playback,
        AudioPlaybackState.idle);

    await tester.tap(find.byTooltip('播放整段'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));

    final state = container.read(ttsControllerProvider);
    expect(state.playback,
        anyOf(AudioPlaybackState.playing, AudioPlaybackState.loading));
    expect(state.currentSentenceId, anyOf('s_msg1_0', isNull));
  });

  testWidgets('tapping a single sentence updates currentSentenceId',
      (tester) async {
    await tester.pumpWidget(_wrap(
      MessageBubble(message: _sampleMessage(), conversationId: 'c1'),
    ));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessageBubble)),
    );
    await tester.tap(find.text('Today is grey.'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final state = container.read(ttsControllerProvider);
    expect(state.currentSentenceId, 's_msg1_1');
  });

  testWidgets('renders markdown in primary as rich text', (tester) async {
    final message = ChatMessage(
      id: 'msg_md',
      role: MessageRole.assistant,
      createdAt: DateTime(2026),
      response: const CoachResponse(
        intent: CoachIntent.explanation,
        sourceLanguage: 'en',
        targetLanguage: 'zh',
        primary: 'It is **raining**.',
        explanation: '- use *present progressive*\n- add an adverb',
        sentences: [],
      ),
      model: 'Test',
    );
    await tester.pumpWidget(_wrap(
      MessageBubble(message: message, conversationId: 'c1'),
    ));

    // Markdown content should NOT show raw markers to the user.
    expect(find.textContaining('**raining**'), findsNothing);
    expect(find.textContaining('*present progressive*'), findsNothing);

    // And the Markdown widget should be in the tree.
    expect(find.byType(MarkdownBody), findsWidgets);
  });

  testWidgets('plain prose stays on a Text widget', (tester) async {
    await tester.pumpWidget(_wrap(
      MessageBubble(message: _sampleMessage(), conversationId: 'c1'),
    ));
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('It is raining today.'), findsOneWidget);
  });

  testWidgets('last assistant bubble exposes copy + regenerate actions',
      (tester) async {
    var regenerated = 0;
    await tester.pumpWidget(_wrap(
      MessageBubble(
        message: _sampleMessage(),
        conversationId: 'c1',
        isLast: true,
        isStreaming: false,
        onRegenerate: () => regenerated++,
      ),
    ));

    expect(find.byTooltip('复制回答'), findsOneWidget);
    expect(find.byTooltip('重新生成'), findsOneWidget);

    await tester.tap(find.byTooltip('重新生成'));
    expect(regenerated, 1);
  });

  testWidgets('intermediate bubbles hide the action bar', (tester) async {
    await tester.pumpWidget(_wrap(
      MessageBubble(
        message: _sampleMessage(),
        conversationId: 'c1',
        isLast: false,
        onRegenerate: () {},
      ),
    ));
    expect(find.byTooltip('复制回答'), findsNothing);
    expect(find.byTooltip('重新生成'), findsNothing);
  });

  testWidgets('streaming hides the action bar until the reply settles',
      (tester) async {
    await tester.pumpWidget(_wrap(
      MessageBubble(
        message: _sampleMessage(),
        conversationId: 'c1',
        isLast: true,
        isStreaming: true,
        onRegenerate: () {},
      ),
    ));
    expect(find.byTooltip('复制回答'), findsNothing);
    expect(find.byTooltip('重新生成'), findsNothing);
  });
}
