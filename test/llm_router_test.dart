import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

class _StubProvider implements LlmProvider {
  const _StubProvider(this.id);
  @override
  final String id;
  @override
  Future<CoachResponse> generate(CoachRequest request) async =>
      DemoLlmProvider(id).generate(request);
}

void main() {
  late LlmRouter router;
  setUp(() {
    router = LlmRouter(
      manualMiniMax: const _StubProvider('MiniMax'),
      manualDeepSeek: const _StubProvider('DeepSeek'),
      localQwen: const _StubProvider('Qwen3'),
    );
  });

  test('explicit selection bypasses auto', () {
    expect(router.resolve(AiProvider.miniMax, CoachIntent.conversation).id,
        'MiniMax');
    expect(router.resolve(AiProvider.deepSeek, CoachIntent.conversation).id,
        'DeepSeek');
    expect(router.resolve(AiProvider.localQwen, CoachIntent.conversation).id,
        'Qwen3');
  });

  test('auto routes grammar / correction / explanation to DeepSeek', () {
    expect(router.resolve(AiProvider.auto, CoachIntent.grammarQuestion).id,
        'DeepSeek');
    expect(router.resolve(AiProvider.auto, CoachIntent.correction).id,
        'DeepSeek');
    expect(router.resolve(AiProvider.auto, CoachIntent.explanation).id,
        'DeepSeek');
  });

  test('auto routes conversation / expression / roleplay to MiniMax', () {
    expect(router.resolve(AiProvider.auto, CoachIntent.conversation).id,
        'MiniMax');
    expect(router.resolve(AiProvider.auto, CoachIntent.expressionHelp).id,
        'MiniMax');
    expect(router.resolve(AiProvider.auto, CoachIntent.roleplay).id, 'MiniMax');
  });
}