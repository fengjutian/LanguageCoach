import '../models/app_settings.dart';
import '../models/chat_models.dart';
import 'llm_event.dart';

class CoachRequest {
  const CoachRequest({
    required this.text,
    required this.targetLanguage,
    required this.intent,
    this.languageChangedDuringConversation = false,
  });
  final String text;
  final CoachLanguage targetLanguage;
  final CoachIntent intent;

  /// True when the conversation history was produced in a different language
  /// than this turn's target. Providers turn this into an explicit
  /// "from this turn on, answer in X" instruction — a mixed-language
  /// transcript otherwise pulls the model back to the old language.
  final bool languageChangedDuringConversation;
}

/// Provider contract used by [ConversationEngine]. The current interface is
/// deliberately streaming so the chat UI can render partial text, support
/// stop / cancel, and surface error cards. Real network providers (MiniMax,
/// DeepSeek) and the local Qwen provider all sit behind this boundary.
abstract interface class LlmProvider {
  String get id;

  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  );
}

/// Fallback provider used until real keys are configured. Returns a single
/// canned sentence per language so the chat surface stays exercisable
/// without external credentials.
class DemoLlmProvider implements LlmProvider {
  const DemoLlmProvider(this.id);
  @override
  final String id;

  @override
  Stream<LlmEvent> generateStream(
    CoachRequest request,
    List<ChatMessage> context,
  ) async* {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final sample = switch (request.targetLanguage) {
      CoachLanguage.english => "It's raining today.",
      CoachLanguage.japanese => '今日は雨が降っています。',
      CoachLanguage.french => "Il pleut aujourd'hui.",
      CoachLanguage.korean => '오늘은 비가 와요.',
      CoachLanguage.spanish => 'Hoy está lloviendo.',
      CoachLanguage.german => 'Heute regnet es.',
      CoachLanguage.italian => 'Oggi piove.',
      CoachLanguage.chinese => '今天下雨。',
      CoachLanguage.russian => 'Сегодня идёт дождь.',
      CoachLanguage.portuguese => 'Está chovendo hoje.',
    };
    yield LlmEventDelta(sample);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    yield LlmEventComplete(
      CoachResponse(
        intent: request.intent,
        sourceLanguage: 'auto',
        targetLanguage: request.targetLanguage.code,
        primary: sample,
        alternatives: request.targetLanguage == CoachLanguage.english
            ? const ["It's rainy today."]
            : const <String>[],
        explanation: '这是符合目标语言日常习惯的自然表达。接入真实模型后，解释会结合输入和上下文生成。',
        sentences: [CoachSentence(id: 's1', text: sample)],
        keywords: const ['rain'],
      ),
      ChatMessage(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        role: MessageRole.assistant,
        createdAt: DateTime.now(),
        response: CoachResponse(
          intent: request.intent,
          sourceLanguage: 'auto',
          targetLanguage: request.targetLanguage.code,
          primary: sample,
          alternatives: request.targetLanguage == CoachLanguage.english
              ? const ["It's rainy today."]
              : const <String>[],
          explanation: '这是符合目标语言日常习惯的自然表达。接入真实模型后，解释会结合输入和上下文生成。',
          sentences: [CoachSentence(id: 's1', text: sample)],
          keywords: const ['rain'],
        ),
        model: id,
      ),
    );
  }
}
