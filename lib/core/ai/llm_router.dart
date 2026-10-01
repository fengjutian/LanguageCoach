import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Picks the [LlmProvider] for a given intent under the user's chosen routing
/// policy. Kept as a dedicated object so it can be replaced (e.g. with a real
/// network-aware router in P0-2) without touching [ConversationEngine].
class LlmRouter {
  LlmRouter({
    required LlmProvider manualMiniMax,
    required LlmProvider manualDeepSeek,
    required LlmProvider localQwen,
  })  : _manualMiniMax = manualMiniMax,
        _manualDeepSeek = manualDeepSeek,
        _localQwen = localQwen;

  final LlmProvider _manualMiniMax;
  final LlmProvider _manualDeepSeek;
  final LlmProvider _localQwen;

  /// Resolution rules mirror the planned router policy:
  ///   - explicit user choice wins;
  ///   - `auto` routes grammar/correction/explanation to DeepSeek and
  ///     conversation/expression/roleplay to MiniMax;
  ///   - `localQwen` falls back to the local provider, which is expected to
  ///     surface a clear "model not installed" error when called.
  LlmProvider resolve(AiProvider selected, CoachIntent intent) {
    switch (selected) {
      case AiProvider.miniMax:
        return _manualMiniMax;
      case AiProvider.deepSeek:
        return _manualDeepSeek;
      case AiProvider.localQwen:
        return _localQwen;
      case AiProvider.auto:
        if (intent == CoachIntent.grammarQuestion ||
            intent == CoachIntent.correction ||
            intent == CoachIntent.explanation) {
          return _manualDeepSeek;
        }
        return _manualMiniMax;
    }
  }
}