import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ai/conversation_engine.dart';
import '../../../core/ai/llm_router.dart';
import '../../../core/ai/local_qwen_provider.dart';
import '../../../core/ai/minimax_provider.dart';
import '../../../core/audio/model_manifest.dart';
import '../../../core/config/app_config.dart';
import '../../../core/native/native_ai_bridge.dart';
import '../../../core/network/api_client.dart';
import '../../../core/security/secure_key_store.dart';
import '../../settings/application/settings_controller.dart';

final appConfigProvider = Provider<AppConfig>((ref) {
  return AppConfig.defaultAppConfig;
});

final apiClientProvider = Provider<ApiClient>((ref) => ApiClient());

final secureKeyStoreProvider = Provider<SecureKeyStore>((ref) {
  return SecureKeyStore();
});

/// In-process router. Real network providers are injected here; tests swap
/// individual providers via `llmRouterProvider.overrideWith(...)`.
final llmRouterProvider = Provider<LlmRouter>((ref) {
  final config = ref.watch(appConfigProvider);
  final apiClient = ref.watch(apiClientProvider);
  final keyStore = ref.watch(secureKeyStoreProvider);
  final bridge = ref.watch(nativeAiBridgeProvider);

  return LlmRouter(
    manualMiniMax: MiniMaxProvider(
      endpoint: config.miniMax,
      apiClient: apiClient,
      apiKeyResolver: () => keyStore.read(ApiKeySlot.miniMax),
    ),
    manualDeepSeek: DeepSeekProvider(
      endpoint: config.deepSeek,
      apiClient: apiClient,
      apiKeyResolver: () => keyStore.read(ApiKeySlot.deepSeek),
    ),
    // The bridge decides whether the model is resident at runtime — when
    // it isn't, `startLlmGeneration` returns null and the stream emits a
    // localised "model not loaded" error. Keeping a fallback slot around
    // for tests that want to assert on the not-installed UX directly.
    localQwen: LocalQwenProvider(
      bridge: bridge,
      modelId: qwen3Llm06B.id,
    ),
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
