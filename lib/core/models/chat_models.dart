// CoachRequest intentionally lives in core/ai/llm_provider.dart so the
// request type and provider interface stay co-located; importing it here would
// produce an ambiguous-import error.

/// User-facing intents the coach recognises. The order is meaningful for
/// `indexOf` lookups and intentionally omits an `unknown` member so that
/// `values.firstWhere(..., orElse: () => conversation)` stays deterministic.
/// Unknown JSON values fall back to [CoachIntent.conversation] in [fromJson].
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

/// One sentence inside a [CoachResponse]. Stable across conversation turns so
/// the UI can keep references after a re-render or audio cache hit.
class CoachSentence {
  const CoachSentence({required this.id, required this.text});

  final String id;
  final String text;

  factory CoachSentence.fromJson(Object? raw) {
    if (raw is Map) {
      final id = raw['id'];
      final text = raw['text'];
      return CoachSentence(
        id: id is String && id.isNotEmpty
            ? id
            : 's_${DateTime.now().microsecondsSinceEpoch}',
        text: text?.toString() ?? '',
      );
    }
    if (raw is String) {
      return CoachSentence(id: 's_${raw.hashCode}', text: raw);
    }
    return const CoachSentence(id: 's_empty', text: '');
  }

  Map<String, Object?> toJson() => {'id': id, 'text': text};
}

/// The structured payload we expect from the LLM. Layout matches the
/// technical design: `intent / sourceLanguage / targetLanguage / answer /
/// sentences / learning`. `learning.{difficulty,keywords}` collapse into
/// [keywords] until we add difficulty in a later milestone.
class CoachResponse {
  const CoachResponse({
    required this.intent,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.primary,
    required this.explanation,
    required this.sentences,
    this.alternatives = const <String>[],
    this.keywords = const <String>[],
  });

  final CoachIntent intent;
  final String sourceLanguage;
  final String targetLanguage;
  final String primary;
  final List<String> alternatives;
  final String explanation;
  final List<CoachSentence> sentences;
  final List<String> keywords;

  factory CoachResponse.fromJson(Map<Object?, Object?> raw) {
    final intentRaw = raw['intent'];
    final intent = CoachIntent.values.firstWhere(
      (v) => v.name == intentRaw,
      orElse: () => CoachIntent.conversation,
    );

    final primary = raw['primary']?.toString() ?? '';

    final sentences = <CoachSentence>[];
    final sentencesRaw = raw['sentences'];
    if (sentencesRaw is List) {
      for (final item in sentencesRaw) {
        if (item is Map || item is String) {
          sentences.add(CoachSentence.fromJson(item));
        }
      }
    }

    // The design mandates that empty `sentences` are auto-populated from the
    // `primary` answer so the audio/UI layer always has at least one item to
    // play.
    if (sentences.isEmpty && primary.isNotEmpty) {
      sentences.add(
        CoachSentence(id: 'auto_1', text: primary),
      );
    }

    return CoachResponse(
      intent: intent,
      sourceLanguage: raw['sourceLanguage']?.toString() ?? 'auto',
      targetLanguage: raw['targetLanguage']?.toString() ?? '',
      primary: primary,
      alternatives: _readStringList(raw['alternatives']),
      explanation: raw['explanation']?.toString() ?? '',
      sentences: List.unmodifiable(sentences),
      keywords: _readStringList(raw['keywords']),
    );
  }

  Map<String, Object?> toJson() => {
        'intent': intent.name,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
        'primary': primary,
        'alternatives': alternatives,
        'explanation': explanation,
        'sentences': sentences.map((s) => s.toJson()).toList(),
        'keywords': keywords,
      };
}

List<String> _readStringList(Object? raw) {
  if (raw is List) {
    return raw.whereType<String>().toList(growable: false);
  }
  return const <String>[];
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

  factory ChatMessage.fromJson(Map<Object?, Object?> raw) {
    final roleRaw = raw['role']?.toString() ?? MessageRole.user.name;
    final role = MessageRole.values.firstWhere(
      (r) => r.name == roleRaw,
      orElse: () => MessageRole.user,
    );

    final createdRaw = raw['createdAt']?.toString();
    final createdAt = DateTime.tryParse(createdRaw ?? '') ?? DateTime.now();

    final responseRaw = raw['response'];
    CoachResponse? response;
    if (responseRaw is Map) {
      response = CoachResponse.fromJson(responseRaw.cast<Object?, Object?>());
    }

    return ChatMessage(
      id: raw['id']?.toString() ?? 'm_${DateTime.now().microsecondsSinceEpoch}',
      role: role,
      createdAt: createdAt,
      sourceText: raw['sourceText']?.toString(),
      response: response,
      model: raw['model']?.toString(),
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'createdAt': createdAt.toIso8601String(),
        'sourceText': sourceText,
        'response': response?.toJson(),
        'model': model,
      };
}
