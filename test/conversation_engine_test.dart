import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/conversation_engine.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Records every call the engine makes so router selection is observable
/// without waiting for the LLM response.
class _CountingProvider implements LlmProvider {
  _CountingProvider(this.id);
  @override
  final String id;
  int calls = 0;
  final List<CoachRequest> seen = <CoRequestImpl>[];

  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) async* {
    calls++;
    seen.add(request);
    yield LlmEventComplete(
      CoachResponse(
        intent: request.intent,
        sourceLanguage: 'auto',
        targetLanguage: request.targetLanguage.code,
        primary: 'ok',
        explanation: '',
        sentences: const <CoachSentence>[],
      ),
      ChatMessage(
        id: 'm',
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: CoachResponse(
          intent: request.intent,
          sourceLanguage: 'auto',
          targetLanguage: request.targetLanguage.code,
          primary: 'ok',
          explanation: '',
          sentences: const <CoachSentence>[],
        ),
        model: id,
      ),
    );
  }
}

ConversationEngine _engineWith(_CountingProvider minimax,
    _CountingProvider deepSeek, _CountingProvider localQwen) {
  return ConversationEngine(
    settings: AppSettings.defaults,
    router: LlmRouter(
      manualMiniMax: minimax,
      manualDeepSeek: deepSeek,
      localQwen: localQwen,
    ),
  );
}

Future<void> _drain(Stream<LlmEvent> stream) async {
  await for (final _ in stream) {
    // no-op — call the interest above so router can increment counters
  }
}

void main() {
  test('detects core intents', () {
    final engine = _engineWith(
      _CountingProvider('m'),
      _CountingProvider('d'),
      _CountingProvider('q'),
    );
    expect(engine.detectIntent('为什么这里用 raining？'), CoachIntent.grammarQuestion);
    expect(engine.detectIntent('今天下雨怎么用英语表达？'), CoachIntent.expressionHelp);
    expect(engine.detectIntent('和我模拟酒店入住'), CoachIntent.roleplay);
    expect(engine.detectIntent('随便聊聊'), CoachIntent.conversation);
    expect(engine.detectIntent('南京'), CoachIntent.vocabulary);
    expect(engine.detectIntent('serendipity'), CoachIntent.vocabulary);
  });

  test('auto router sends grammar/correction/explanation to DeepSeek',
      () async {
    final minimax = _CountingProvider('MiniMax');
    final deepSeek = _CountingProvider('DeepSeek');
    final engine = _engineWith(minimax, deepSeek, _CountingProvider('Qwen'));
    await _drain(engine.replyStream('为什么这里用 raining？'));
    await _drain(engine.replyStream('帮我纠正这句话'));
    expect(deepSeek.calls, 2);
    expect(minimax.calls, 0);
  });

  test('auto router sends conversation/expression/roleplay to MiniMax',
      () async {
    final minimax = _CountingProvider('MiniMax');
    final deepSeek = _CountingProvider('DeepSeek');
    final engine = _engineWith(minimax, deepSeek, _CountingProvider('Qwen'));
    await _drain(engine.replyStream('和我模拟酒店入住'));
    await _drain(engine.replyStream('怎么说谢谢'));
    expect(minimax.calls, 2);
    expect(deepSeek.calls, 0);
  });

  test('manual provider overrides auto routing', () async {
    final minimax = _CountingProvider('MiniMax');
    final deepSeek = _CountingProvider('DeepSeek');
    final localQwen = _CountingProvider('Qwen');
    final localSettings = AppSettings.defaults.copyWith(
      provider: AiProvider.deepSeek,
    );
    final engine = ConversationEngine(
      settings: localSettings,
      router: LlmRouter(
        manualMiniMax: minimax,
        manualDeepSeek: deepSeek,
        localQwen: localQwen,
      ),
    );
    await _drain(engine.replyStream('为什么这里用 raining？'));
    expect(deepSeek.calls, 1);
    expect(minimax.calls, 0);
    expect(localQwen.calls, 0);
  });

  test('local provider error short-circuits the stream', () async {
    final local = LocalModelNotInstalledProvider();
    final engine = ConversationEngine(
      settings: AppSettings.defaults.copyWith(provider: AiProvider.localQwen),
      router: LlmRouter(
        manualMiniMax: _CountingProvider('m'),
        manualDeepSeek: _CountingProvider('d'),
        localQwen: local,
      ),
    );
    final events = <LlmEvent>[];
    await for (final e in engine.replyStream('test')) {
      events.add(e);
    }
    expect(events, isNotEmpty);
    expect(events.last, isA<LlmEventError>());
  });
}

// Helper typedef so `_CountingProvider.seen.add(request)` compiles without
// exposing CoachRequest in unrelated test scopes.
typedef CoRequestImpl = CoachRequest;
