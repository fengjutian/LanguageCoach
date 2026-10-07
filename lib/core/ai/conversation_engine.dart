import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/language/target_language_resolver.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Pure orchestrator: target-language resolution -> intent detection ->
/// router selection -> provider call -> wrap as [LlmEvent].
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
    if (text.contains('解释') ||
        text.contains('explain') ||
        text.contains('explanation')) {
      return CoachIntent.explanation;
    }
    if (text.contains('角色') ||
        text.contains('模拟') ||
        text.contains('roleplay')) {
      return CoachIntent.roleplay;
    }
    if (text.contains('怎么说') || text.contains('表达')) {
      return CoachIntent.expressionHelp;
    }
    // A bare word or very short CJK fragment usually means "teach me this
    // expression" in a language-coaching chat. Classifying it as ordinary
    // conversation made inputs such as “南京” receive a bare translation
    // without pronunciation or usage guidance.
    final compact = text.trim();
    final isShortCjkTerm = RegExp(r'^[\u3400-\u9fff]{1,3}$').hasMatch(compact);
    final isSingleLatinTerm = RegExp(r"^[a-z][a-z'-]{1,24}$").hasMatch(compact);
    if (isShortCjkTerm || isSingleLatinTerm) {
      return CoachIntent.vocabulary;
    }
    return CoachIntent.conversation;
  }

  /// Resolves target + intent, picks a provider through [router], and yields
  /// [LlmEvent]s the chat UI can stream directly. The engine itself never
  /// touches concrete provider wiring; tests inject a fake by overriding
  /// [llmRouterProvider].
  Stream<LlmEvent> replyStream(
    String input, {
    List<ChatMessage> context = const <ChatMessage>[],
  }) async* {
    final target = _languageResolver.resolve(input, settings.preferredLanguage);
    final intent = detectIntent(input);
    final provider = router.resolve(settings.provider, intent);
    final request = CoachRequest(
      text: input,
      targetLanguage: target,
      intent: intent,
    );

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    DateTime? createdAt;

    await for (final event in provider.generateStream(request, context)) {
      switch (event) {
        case LlmEventDelta():
          yield event;
        case LlmEventThinking():
          yield event;
        case LlmEventComplete(:final response):
          createdAt ??= DateTime.now();
          yield LlmEventComplete(
            response,
            ChatMessage(
              id: id,
              role: MessageRole.assistant,
              createdAt: createdAt,
              response: response,
              model: provider.id,
            ),
          );
        case LlmEventError():
          yield event;
      }
    }
  }
}
