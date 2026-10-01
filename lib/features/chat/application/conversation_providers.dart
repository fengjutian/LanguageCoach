import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ai/conversation_engine.dart';
import '../../../core/ai/llm_provider.dart';
import '../../../core/ai/llm_router.dart';
import '../../../core/native/native_ai_bridge.dart';
import '../../settings/application/settings_controller.dart';

/// In-process router that wires the [LlmProvider] implementations into the
/// [ConversationEngine]. P0-2 replaces the [DemoLlmProvider] instances with
/// real network providers; the route resolution logic is unchanged.
final llmRouterProvider = Provider<LlmRouter>((ref) {
  return LlmRouter(
    manualMiniMax: const DemoLlmProvider('MiniMax (Demo)'),
    manualDeepSeek: const DemoLlmProvider('DeepSeek (Demo)'),
    localQwen: const DemoLlmProvider('Qwen3 0.6B (Demo)'),
  );
});

/// Conversation engine bound to the current [AppSettings]. The engine itself
/// is stateless — every settings mutation triggers a re-build, which is
/// cheap and keeps the resolved provider in sync with the user's choice.
final conversationEngineProvider = Provider<ConversationEngine>((ref) {
  final settings = ref.watch(settingsControllerProvider);
  final router = ref.watch(llmRouterProvider);
  return ConversationEngine(settings: settings, router: router);
});

/// Native bridge surface for the Kotlin side. Tests override this provider
/// with a [FakeNativeAiBridge] implementation.
final nativeAiBridgeProvider = Provider<NativeAiBridge>((ref) {
  return const DefaultBridge();
});
