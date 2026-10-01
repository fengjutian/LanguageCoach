import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/language/target_language_resolver.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Pure orchestrator: target-language resolution -> intent detection -> router
/// selection -> LLM call -> wrap result. Engine itself never touches
/// concrete provider wiring, which keeps widget tests simple (inject a fake
/// router / provider) and lets P0-2 swap in real network providers without
/// touching this file.
class ConversationEngine {
  ConversationEngine({
    required this.settings,
    required this.router,
    TargetLanguageResolver? resolver,
  }) : _languageResolver = resolver ?? TargetLanguageResolver();

  final AppSettings settings;
  final LlmRouter router;
  final TargetLanguageResolver _languageResolver;

  CoachIntent detectIntent(String input) {
    final text = input.toLowerCase();
    if (text.contains('为什么') || text.contains('grammar')) {
      return CoachIntent.grammarQuestion;
    }
    if (text.contains('纠正') || text.contains('correct')) {
      return CoachIntent.correction;
    }
    if (text.contains('角色') ||
        text.contains('模拟') ||
        text.contains('roleplay')) {
      return CoachIntent.roleplay;
    }
    if (text.contains('怎么说') || text.contains('表达')) {
      return CoachIntent.expressionHelp;
    }
    return CoachIntent.conversation;
  }

  Future<ChatMessage> reply(String input) async {
    final target = _languageResolver.resolve(input, settings.preferredLanguage);
    final intent = detectIntent(input);
    final provider = router.resolve(settings.provider, intent);
    final response = await provider.generate(
      CoachRequest(text: input, targetLanguage: target, intent: intent),
    );
    return ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      role: MessageRole.assistant,
      createdAt: DateTime.now(),
      response: response,
      model: provider.id,
    );
  }
}