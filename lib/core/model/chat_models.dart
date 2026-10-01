enum CoachIntent {
  expressionHelp,
  translation,
  conversation,
  grammarQuestion,
  vocabulary,
  pronunciation,
  correction,
  explanation,
  roleplay,
  practice,
}

enum MessageRole { user, assistant }

class CoachSentence {
  const CoachSentence({required this.id, required this.text});
  final String id;
  final String text;
}

class CoachResponse {
  const CoachResponse({
    required this.intent,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.primary,
    required this.explanation,
    required this.sentences,
    this.alternatives = const [],
    this.keywords = const [],
  });

  final CoachIntent intent;
  final String sourceLanguage;
  final String targetLanguage;
  final String primary;
  final List<String> alternatives;
  final String explanation;
  final List<CoachSentence> sentences;
  final List<String> keywords;
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.createdAt,
    this.sourceText,
    this.response,
    this.model,
  });

  final String id;
  final MessageRole role;
  final DateTime createdAt;
  final String? sourceText;
  final CoachResponse? response;
  final String? model;
}
