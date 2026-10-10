import 'dart:async';

import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/ai/llm_router.dart';
import 'package:language_coach/core/language/target_language_resolver.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:uuid/uuid.dart';

/// The language actually used for one turn, resolved *before* the request is
/// built. "显式指定 > 会话语言 > 英语兜底" — the chat controller captures this
/// into the turn so the provider request, the response label, the TTS voice
/// and the database row all agree, even if the user switches languages or
/// conversations while the stream is still running.
class ResolvedTurnLanguage {
  const ResolvedTurnLanguage({
    required this.language,
    required this.explicit,
  });

  final CoachLanguage language;

  /// True when the learner's text named the language outright. The UI shows
  /// this so the selector doesn't look like it silently lost authority.
  final bool explicit;

  @override
  String toString() =>
      'ResolvedTurnLanguage(${language.name}, explicit: $explicit)';
}

/// Pure orchestrator: target-language resolution -> intent detection ->
/// router selection -> provider call -> wrap as [LlmEvent].
///
/// The engine never reads the global settings for the *turn* language — the
/// caller passes the conversation's language explicitly. Only the model
/// provider selection still comes from settings, and that is a router
/// concern, not a language concern.
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
    // A short CJK term (2-3 characters) or a single Latin word usually means
    // "teach me this expression" in a language-coaching chat. Classifying it as
    // vocabulary gives pronunciation and usage guidance instead of a bare
    // translation. We require at least 2 characters to avoid false positives
    // from casual conversation (e.g., "你好" is vocabulary, "一" is not).
    final compact = text.trim();
    // Skip if it's just punctuation or whitespace.
    if (compact.isEmpty) return CoachIntent.conversation;
    // Require 2-3 CJK characters (not single-char common words like "一", "我").
    final isShortCjkTerm = RegExp(r'^[\u3400-\u9fff]{2,3}$').hasMatch(compact);
    // Require 2+ Latin characters, no leading/trailing punctuation.
    final isSingleLatinTerm =
        RegExp(r"^[a-z][a-z'-]{1,24}$", caseSensitive: false).hasMatch(compact) &&
            compact.length >= 2;
    if (isShortCjkTerm || isSingleLatinTerm) {
      return CoachIntent.vocabulary;
    }
    return CoachIntent.conversation;
  }

  /// Resolves the turn language without contacting a provider. The chat
  /// controller calls this first so it can capture the value for the whole
  /// turn (message label, TTS, DB row) before any streaming starts.
  ResolvedTurnLanguage resolveTurnLanguage(
    String input,
    CoachLanguage conversationLanguage,
  ) {
    final explicit = _languageResolver.resolveExplicit(input);
    return ResolvedTurnLanguage(
      language: explicit ?? conversationLanguage,
      explicit: explicit != null,
    );
  }

  /// Drops messages that must never be replayed to the model: streaming
  /// placeholders, failed turns, cancelled turns, error rows and empties.
  /// Truncation happens in whole turns so the model never sees half a Q/A
  /// pair as the opening message.
  static List<ChatMessage> usableContext(
    List<ChatMessage> messages, {
    String? excludeMessageId,
    int maxTurns = 8,
  }) {
    final eligible = messages
        .where((m) => m.id != excludeMessageId && m.isContextEligible)
        .toList(growable: false);
    if (eligible.isEmpty) return const <ChatMessage>[];
    final budget = maxTurns * 2;
    if (eligible.length <= budget) return List.unmodifiable(eligible);
    final slice = eligible.sublist(eligible.length - budget);
    // Cutting mid-turn leaves a dangling assistant answer with no question.
    // Drop the leading orphan so the context always opens on a user message.
    var start = 0;
    while (start < slice.length && slice[start].role != MessageRole.user) {
      start++;
    }
    if (start >= slice.length) return const <ChatMessage>[];
    return List.unmodifiable(slice.sublist(start));
  }

  /// Resolves target + intent, picks a provider through [router], and yields
  /// [LlmEvent]s the chat UI can stream directly. The engine itself never
  /// touches concrete provider wiring; tests inject a fake by overriding
  /// [llmRouterProvider].
  ///
  /// Built on an explicit [StreamController] rather than `async*` on purpose:
  /// cancelling a subscription to a generator suspended inside `await for`
  /// only resumes once the inner stream produces another event, so "stop
  /// generating" on a quiet connection would never reach the provider — and
  /// the abandoned request would keep running. Here [StreamController.onCancel]
  /// forwards straight to the provider subscription.
  Stream<LlmEvent> replyStream(
    String input, {
    required CoachLanguage conversationLanguage,
    List<ChatMessage> context = const <ChatMessage>[],
    CoachLanguage? overrideTargetLanguage,
  }) {
    final resolved = overrideTargetLanguage != null
        ? ResolvedTurnLanguage(
            language: overrideTargetLanguage,
            explicit: _languageResolver.resolveExplicit(input) != null,
          )
        : resolveTurnLanguage(input, conversationLanguage);
    final intent = detectIntent(input);
    final provider = router.resolve(settings.provider, intent);
    final request = CoachRequest(
      text: input,
      targetLanguage: resolved.language,
      intent: intent,
      // Signal a mid-conversation language switch so the provider can tell
      // the model "from this turn on, answer in X" instead of leaving it to
      // infer from a mixed-language transcript.
      languageChangedDuringConversation:
          _needsLanguageSwitchNotice(context, resolved.language),
    );

    final id = const Uuid().v4();
    final createdAt = DateTime.now();

    final controller = StreamController<LlmEvent>();
    StreamSubscription<LlmEvent>? inner;
    var cancelled = false;

    controller.onListen = () {
      inner = provider.generateStream(request, context).listen(
            (event) {
              if (cancelled || controller.isClosed) return;
              switch (event) {
                case LlmEventDelta():
                case LlmEventThinking():
                  controller.add(event);
                case LlmEventComplete(:final response):
                  // Last line of defence: whatever the provider produced, the
                  // turn's language is the one the client resolved and captured.
                  final authoritative = response.copyWith(
                    targetLanguage: request.targetLanguage.code,
                    intent: request.intent,
                  );
                  controller.add(LlmEventComplete(
                    authoritative,
                    ChatMessage(
                      id: id,
                      role: MessageRole.assistant,
                      createdAt: createdAt,
                      response: authoritative,
                      model: provider.id,
                      status: ChatMessageStatus.completed,
                      languageMismatch: looksLikeLanguageMismatch(
                        authoritative.primary,
                        request.targetLanguage.code,
                      ),
                    ),
                  ));
                case LlmEventError():
                  controller.add(event);
              }
            },
            onError: controller.addError,
            onDone: () {
              if (!controller.isClosed) unawaited(controller.close());
            },
            cancelOnError: false,
          );
    };

    controller.onCancel = () async {
      cancelled = true;
      await inner?.cancel();
      inner = null;
    };

    return controller.stream;
  }

  /// A conversation whose recent history was in another language needs an
  /// explicit "switch now" instruction; an all-history-in-target-language
  /// conversation does not.
  bool _needsLanguageSwitchNotice(
    List<ChatMessage> context,
    CoachLanguage turnLanguage,
  ) {
    for (final m in context.reversed) {
      final lang = m.response?.targetLanguage;
      if (lang != null && lang.isNotEmpty && lang != 'auto') {
        return lang != turnLanguage.code;
      }
    }
    return false;
  }
}
