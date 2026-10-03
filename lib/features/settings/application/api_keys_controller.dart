import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/security/secure_key_store.dart';
import '../../chat/application/conversation_providers.dart';
import '../../chat/application/tts_controller.dart';

/// State holds masked previews (last 4 chars + dots) — the full key never
/// lives in this notifier. `null` means "not configured".
class ApiKeysController extends AsyncNotifier<Map<ApiKeySlot, String?>> {
  @override
  Future<Map<ApiKeySlot, String?>> build() => _readAll();

  Future<Map<ApiKeySlot, String?>> _readAll() async {
    final store = ref.read(secureKeyStoreProvider);
    return {
      ApiKeySlot.miniMax: await store.masked(ApiKeySlot.miniMax),
      ApiKeySlot.deepSeek: await store.masked(ApiKeySlot.deepSeek),
    };
  }

  Future<void> write(ApiKeySlot slot, String value) async {
    await ref.read(secureKeyStoreProvider).write(slot, value);
    // The TTS engine selector watches the MiniMax API key as a
    // FutureProvider — invalidate it so the next read picks up the
    // freshly-written key instead of the cached value the selector
    // captured on first build.
    if (slot == ApiKeySlot.miniMax) {
      ref.invalidate(miniMaxTtsApiKeyProvider);
    }
    state = AsyncValue.data(await _readAll());
  }

  Future<void> delete(ApiKeySlot slot) async {
    await ref.read(secureKeyStoreProvider).delete(slot);
    if (slot == ApiKeySlot.miniMax) {
      ref.invalidate(miniMaxTtsApiKeyProvider);
    }
    state = AsyncValue.data(await _readAll());
  }

  Future<String?> readRaw(ApiKeySlot slot) =>
      ref.read(secureKeyStoreProvider).read(slot);
}

final apiKeysControllerProvider =
    AsyncNotifierProvider<ApiKeysController, Map<ApiKeySlot, String?>>(
  ApiKeysController.new,
);

/// Convenience selector — masked preview for a single slot. UI prefers this
/// to avoid watching the entire map.
final maskedKeyProvider = Provider.family<String?, ApiKeySlot>((ref, slot) {
  final state = ref.watch(apiKeysControllerProvider);
  return state.value?[slot];
});
