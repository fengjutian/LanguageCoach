import '../models/app_settings.dart';
import '../models/chat_models.dart';

class CoachRequest {
  const CoachRequest({
    required this.text,
    required this.targetLanguage,
    required this.intent,
  });
  final String text;
  final CoachLanguage targetLanguage;
  final CoachIntent intent;
}

/// Provider contract used by [ConversationEngine]. The current interface is
/// deliberately small; P0-2 widens this to a streaming `Stream<LlmEvent>` so
/// the chat UI can render partial text. Real network providers (MiniMax,
/// DeepSeek) and the local Qwen provider all sit behind this boundary.
abstract interface class LlmProvider {
  String get id;

  Future<CoachResponse> generate(CoachRequest request);
}

/// Fallback provider used until P0-2 wires real network calls. It returns
/// a single canned sentence per language so the rest of the chat surface
/// stays exercisable without external credentials.
class DemoLlmProvider implements LlmProvider {
  const DemoLlmProvider(this.id);
  @override
  final String id;

  @override
  Future<CoachResponse> generate(CoachRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 650));
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
    return CoachResponse(
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
    );
  }
}