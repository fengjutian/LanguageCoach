import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/security/secure_key_store.dart';
import 'package:language_coach/features/chat/application/conversation_providers.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';
import 'package:language_coach/features/settings/application/api_keys_controller.dart';

class _InMemoryKeyStore implements SecureKeyStore {
  _InMemoryKeyStore();

  final Map<ApiKeySlot, String> _store = {};

  @override
  Future<String?> read(ApiKeySlot slot) async => _store[slot];

  @override
  Future<void> write(ApiKeySlot slot, String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await delete(slot);
      return;
    }
    _store[slot] = trimmed;
  }

  @override
  Future<void> delete(ApiKeySlot slot) async {
    _store.remove(slot);
  }

  @override
  Future<String?> masked(ApiKeySlot slot) async {
    final value = _store[slot];
    if (value == null || value.isEmpty) return null;
    if (value.length <= 4) return '••••';
    return '••••${value.substring(value.length - 4)}';
  }
}

void main() {
  test('write+delete on the MiniMax slot invalidates miniMaxTtsApiKeyProvider',
      () async {
    final store = _InMemoryKeyStore();
    final container = ProviderContainer(overrides: [
      secureKeyStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    // First read returns null (no key configured).
    expect(await container.read(miniMaxTtsApiKeyProvider.future), isNull);

    // Cache the value inside the FutureProvider.
    await container.read(miniMaxTtsApiKeyProvider.future);

    // Write a key through the controller; without invalidate() the next
    // read of the FutureProvider would still serve the cached `null`.
    await container
        .read(apiKeysControllerProvider.notifier)
        .write(ApiKeySlot.miniMax, 'sk-first');

    expect(await container.read(miniMaxTtsApiKeyProvider.future), 'sk-first');

    // Update the key — the cached FutureProvider must refresh.
    await container
        .read(apiKeysControllerProvider.notifier)
        .write(ApiKeySlot.miniMax, 'sk-second');

    expect(await container.read(miniMaxTtsApiKeyProvider.future), 'sk-second');

    // Delete clears it back to null.
    await container
        .read(apiKeysControllerProvider.notifier)
        .delete(ApiKeySlot.miniMax);

    expect(await container.read(miniMaxTtsApiKeyProvider.future), isNull);
  });

  test('mutations on the DeepSeek slot do not touch the MiniMax provider',
      () async {
    final store = _InMemoryKeyStore();
    final container = ProviderContainer(overrides: [
      secureKeyStoreProvider.overrideWithValue(store),
    ]);
    addTearDown(container.dispose);

    await container.read(miniMaxTtsApiKeyProvider.future);

    await container
        .read(apiKeysControllerProvider.notifier)
        .write(ApiKeySlot.deepSeek, 'sk-deepseek');

    // MiniMax provider is unaffected — it should still resolve to null
    // without spinning a new build (cached).
    final cached = container.read(miniMaxTtsApiKeyProvider);
    expect(cached, isA<AsyncData<String?>>());
    expect((cached as AsyncData<String?>).value, isNull);
  });
}