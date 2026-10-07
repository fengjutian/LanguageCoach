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

enum MessageRole { user, assistant, error }

/// Lifecycle of an assistant turn. Only [completed] messages are allowed into
/// the request context — a placeholder, a truncated cancel or a failed turn
/// would otherwise be replayed to the model on the next send.
enum ChatMessageStatus {
  /// Still receiving tokens. Excluded from context.
  streaming,

  /// Terminal, playable, persisted. The only status that enters context.
  completed,

  /// Provider or transport failure. Kept visible as an error bubble.
  failed,

  /// User stopped generation. Whatever text arrived is kept but the turn is
  /// not fed back to the model.
  cancelled,
}

/// Lightweight script check used to flag "asked for Japanese, answered in
/// English" without shipping a full language detector. Returns `true` when
/// the text clearly cannot be the requested language.
bool looksLikeLanguageMismatch(String text, String targetCode) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  final code = targetCode.toLowerCase();
  final hasKana = RegExp(r'[\u3040-\u30ff]').hasMatch(trimmed);
  final hasHangul = RegExp(r'[\uac00-\ud7af]').hasMatch(trimmed);
  final hasHan = RegExp(r'[\u4e00-\u9fff]').hasMatch(trimmed);
  final hasCyrillic = RegExp(r'[\u0400-\u04ff]').hasMatch(trimmed);
  final latinChars = RegExp(r'[A-Za-z]').allMatches(trimmed).length;
  final latinRatio = latinChars / trimmed.length;

  switch (code) {
    case 'ja':
      // Japanese without a single kana that is overwhelmingly latin is an
      // English (or romanised) answer, not Japanese.
      return !hasKana && !hasHan && latinRatio > 0.5;
    case 'ko':
      return !hasHangul && !hasHan && latinRatio > 0.5;
    case 'zh-cn':
    case 'zh':
      return !hasHan && latinRatio > 0.7;
    case 'ru':
      return !hasCyrillic && latinRatio > 0.5;
    case 'en':
      // Asking for English and getting pure CJK / kana / hangul / Cyrillic:
      // a romanisation or an explanation leaked into the answer slot.
      return latinChars == 0 && (hasHan || hasKana || hasHangul || hasCyrillic);
    default:
      return false;
  }
}

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
///
/// [thinking] carries the model's reasoning trace (`<think>...</think>`,
/// DeepSeek `delta.reasoning_content`, or a JSON `"thinking"` field) so the
/// UI can show it in a collapsible section without leaking it into the
/// primary answer the user reads.
class CoachResponse {
  const CoachResponse({
    required this.intent,
    required this.sourceLanguage,
    required this.targetLanguage,
    required this.primary,
    required this.explanation,
    required this.sentences,
    this.thinking = '',
    this.alternatives = const <String>[],
    this.keywords = const <String>[],
  });

  final CoachIntent intent;
  final String sourceLanguage;
  final String targetLanguage;
  final String primary;
  final String thinking;
  final List<String> alternatives;
  final String explanation;
  final List<CoachSentence> sentences;
  final List<String> keywords;

  CoachResponse copyWith({
    CoachIntent? intent,
    String? sourceLanguage,
    String? targetLanguage,
    String? primary,
    String? thinking,
    List<String>? alternatives,
    String? explanation,
    List<CoachSentence>? sentences,
    List<String>? keywords,
  }) {
    return CoachResponse(
      intent: intent ?? this.intent,
      sourceLanguage: sourceLanguage ?? this.sourceLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      primary: primary ?? this.primary,
      thinking: thinking ?? this.thinking,
      alternatives: alternatives ?? this.alternatives,
      explanation: explanation ?? this.explanation,
      sentences: sentences ?? this.sentences,
      keywords: keywords ?? this.keywords,
    );
  }

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
      thinking: raw['thinking']?.toString() ?? '',
      alternatives: _readStringList(raw['alternatives']),
      explanation: raw['explanation']?.toString() ?? '',
      sentences: List.unmodifiable(sentences),
      // The prompt documents `learning.keywords` as the canonical layout,
      // but some models emit a flat `keywords` list instead. Read both and
      // never silently drop the vocabulary.
      keywords: _readKeywords(raw),
    );
  }

  Map<String, Object?> toJson() => {
        'intent': intent.name,
        'sourceLanguage': sourceLanguage,
        'targetLanguage': targetLanguage,
        'primary': primary,
        'thinking': thinking,
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

/// Vocabulary can arrive either flat (`keywords`) or nested under the
/// documented `learning` object. Merge both, flat first, de-duplicated.
List<String> _readKeywords(Map<Object?, Object?> raw) {
  final flat = _readStringList(raw['keywords']);
  final learning = raw['learning'];
  final nested = learning is Map
      ? _readStringList(learning['keywords'])
      : const <String>[];
  if (flat.isEmpty) return nested;
  if (nested.isEmpty) return flat;
  return List<String>.unmodifiable(<String>{...flat, ...nested});
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.createdAt,
    this.sourceText,
    this.response,
    this.model,
    this.status = ChatMessageStatus.completed,
    this.languageMismatch = false,
  });

  final String id;
  final MessageRole role;
  final DateTime createdAt;
  final String? sourceText;
  final CoachResponse? response;
  final String? model;

  /// Assistant turns start as [ChatMessageStatus.streaming] and settle on
  /// complete / fail / cancel. User messages are always [completed].
  final ChatMessageStatus status;

  /// Set when the script check found the answer is not in the requested
  /// target language. Drives the "语言不符" hint + regenerate affordance.
  final bool languageMismatch;

  bool get isContextEligible =>
      status == ChatMessageStatus.completed &&
      role != MessageRole.error &&
      ((response?.primary ?? '').trim().isNotEmpty ||
          (sourceText ?? '').trim().isNotEmpty);

  ChatMessage copyWith({
    String? id,
    MessageRole? role,
    DateTime? createdAt,
    String? sourceText,
    CoachResponse? response,
    String? model,
    ChatMessageStatus? status,
    bool? languageMismatch,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
      sourceText: sourceText ?? this.sourceText,
      response: response ?? this.response,
      model: model ?? this.model,
      status: status ?? this.status,
      languageMismatch: languageMismatch ?? this.languageMismatch,
    );
  }

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

    final statusRaw = raw['status']?.toString();
    final status = ChatMessageStatus.values.firstWhere(
      (s) => s.name == statusRaw,
      orElse: () => ChatMessageStatus.completed,
    );

    return ChatMessage(
      id: raw['id']?.toString() ?? 'm_${DateTime.now().microsecondsSinceEpoch}',
      role: role,
      createdAt: createdAt,
      sourceText: raw['sourceText']?.toString(),
      response: response,
      model: raw['model']?.toString(),
      status: status,
      languageMismatch: raw['languageMismatch'] == true,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'role': role.name,
        'createdAt': createdAt.toIso8601String(),
        'sourceText': sourceText,
        'response': response?.toJson(),
        'model': model,
        'status': status.name,
        'languageMismatch': languageMismatch,
      };
}
