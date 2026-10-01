import '../language/target_language_resolver.dart';
import '../model/app_settings.dart';
import '../model/chat_models.dart';
import 'llm_provider.dart';

class ConversationEngine {
  ConversationEngine({required this.settings});

  final AppSettings settings;
  final _languageResolver = TargetLanguageResolver();

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
    final provider = _providerFor(intent);
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

  LlmProvider _providerFor(CoachIntent intent) {
    final selected = settings.provider == AiProvider.auto
        ? (intent == CoachIntent.grammarQuestion ||
                intent == CoachIntent.correction
            ? AiProvider.deepSeek
            : AiProvider.miniMax)
        : settings.provider;
    return DemoLlmProvider(switch (selected) {
      AiProvider.auto => 'Auto',
      AiProvider.miniMax => 'MiniMax (Demo)',
      AiProvider.deepSeek => 'DeepSeek (Demo)',
      AiProvider.localQwen => 'Qwen3 0.6B (Demo)',
    });
  }
}
