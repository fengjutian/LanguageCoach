import 'package:language_coach/core/ai/llm_event.dart';
import 'package:language_coach/core/ai/llm_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';
import 'package:language_coach/core/network/api_client.dart';

/// Picks the [LlmProvider] for a given intent under the user's chosen routing
/// policy. Kept as a dedicated object so it can be replaced (e.g. with a real
/// network-aware router in P0-2) without touching [ConversationEngine].
class LlmRouter {
  LlmRouter({
    required LlmProvider manualMiniMax,
    required LlmProvider manualDeepSeek,
    required LlmProvider localQwen,
    LlmProvider? demoProvider,
  })  : _manualMiniMax = manualMiniMax,
        _manualDeepSeek = manualDeepSeek,
        _localQwen = localQwen,
        _demoProvider = demoProvider ?? const DemoLlmProvider('Demo');

  final LlmProvider _manualMiniMax;
  final LlmProvider _manualDeepSeek;
  final LlmProvider _localQwen;
  final LlmProvider _demoProvider;

  /// Resolution rules mirror the planned router policy:
  ///   - explicit user choice wins;
  ///   - `auto` routes grammar/correction/explanation to DeepSeek and
  ///     conversation/expression/roleplay to MiniMax;
  ///   - `localQwen` returns the stub error provider if model not installed;
  ///   - if no API key is configured, falls back to demo provider.
  LlmProvider resolve(
    AiProvider selected,
    CoachIntent intent, {
    bool miniMaxHasKey = true,
    bool deepSeekHasKey = true,
  }) {
    switch (selected) {
      case AiProvider.miniMax:
        return miniMaxHasKey ? _manualMiniMax : _demoProvider;
      case AiProvider.deepSeek:
        return deepSeekHasKey ? _manualDeepSeek : _demoProvider;
      case AiProvider.localQwen:
        // Return the local provider regardless of its type; it will emit
        // a user-friendly "not installed" error if the model is missing.
        return _localQwen;
      case AiProvider.auto:
        if (intent == CoachIntent.grammarQuestion ||
            intent == CoachIntent.correction ||
            intent == CoachIntent.explanation) {
          return deepSeekHasKey ? _manualDeepSeek : _demoProvider;
        }
        return miniMaxHasKey ? _manualMiniMax : _demoProvider;
    }
  }
}

