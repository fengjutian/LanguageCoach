import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

class _StubProvider implements LlmProvider {
  const _StubProvider(this.id);
  @override
  final String id;
  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) async* {
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
    expect(
        router.resolve(AiProvider.auto, CoachIntent.correction).id, 'DeepSeek');
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

  test('local provider surfaces a clear error instead of mock data', () async {
    final local = const LocalModelNotInstalledProvider();
    final events = <LlmEvent>[];
    await for (final e in local.generateStream(
      const CoachRequest(
        text: 'ping',
        targetLanguage: CoachLanguage.english,
        intent: CoachIntent.conversation,
      ),
      const <ChatMessage>[],
    )) {
      events.add(e);
    }
    expect(events, hasLength(1));
    final err = events.single as LlmEventError;
    expect(err.error.message, contains('本地模型未安装'));
  });
}
