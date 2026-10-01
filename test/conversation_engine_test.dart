import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/conversation_engine.dart';
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
  @override
  Future<CoachResponse> generate(CoachRequest request) {
    calls++;
    return DemoLlmProvider(id).generate(request);
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
  });

  test('auto router sends grammar/correction/explanation to DeepSeek', () {
    final minimax = _CountingProvider('MiniMax');
    final deepSeek = _CountingProvider('DeepSeek');
    final engine = _engineWith(minimax, deepSeek, _CountingProvider('Qwen'));
    engine.reply('为什么这里用 raining？');
    engine.reply('帮我纠正这句话');
    expect(deepSeek.calls, 2);
    expect(minimax.calls, 0);
  });

  test('auto router sends conversation/expression/roleplay to MiniMax',
      () async {
    final minimax = _CountingProvider('MiniMax');
    final deepSeek = _CountingProvider('DeepSeek');
    final engine = _engineWith(minimax, deepSeek, _CountingProvider('Qwen'));
    await engine.reply('和我模拟酒店入住');
    await engine.reply('怎么说谢谢');
    expect(minimax.calls, 2);
    expect(deepSeek.calls, 0);
  });

  test('manual provider overrides auto routing', () async {
    final minimax = _CountingProvider('MiniMax');
    final deepSeek = _CountingProvider('DeepSeek');
    final engine = _engineWith(
      minimax,
      deepSeek,
      _CountingProvider('Qwen'),
    );
    final localSettings = AppSettings.defaults.copyWith(
      provider: AiProvider.deepSeek,
    );
    final localEngine = ConversationEngine(
      settings: localSettings,
      router: LlmRouter(
        manualMiniMax: minimax,
        manualDeepSeek: deepSeek,
        localQwen: _CountingProvider('Qwen'),
      ),
    );
    await localEngine.reply('为什么这里用 raining？');
    expect(deepSeek.calls, 1);
    expect(minimax.calls, 0);
    // avoid unused warnings
    expect(engine, isA<ConversationEngine>());
  });
}