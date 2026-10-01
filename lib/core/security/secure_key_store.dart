import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Identifiers for the two network providers. Adding a new one means
/// extending [_secureKeyProvider] below.
enum ApiKeySlot { miniMax, deepSeek }

/// Persistent storage for provider API keys. Lives in the OS keychain /
/// keystore via [FlutterSecureStorage]; nothing is written to SQLite or
/// in-memory caches. The UI layer only ever reads [masked] for any kind of
/// display — keys themselves stay inside [_secureKeyStore].
class SecureKeyStore {
  SecureKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<String?> read(ApiKeySlot slot) => _storage.read(key: _keyFor(slot));

  Future<void> write(ApiKeySlot slot, String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await _storage.delete(key: _keyFor(slot));
      return;
    }
    await _storage.write(key: _keyFor(slot), value: trimmed);
  }

  Future<void> delete(ApiKeySlot slot) => _storage.delete(key: _keyFor(slot));

  /// Returns a UI-safe preview of the key (last 4 chars only) or `null`
  /// when no key is stored. Never returns the full secret.
  Future<String?> masked(ApiKeySlot slot) async {
    final value = await read(slot);
    if (value == null || value.isEmpty) return null;
    if (value.length <= 4) return '••••';
    return '••••${value.substring(value.length - 4)}';
  }

  String _keyFor(ApiKeySlot slot) => switch (slot) {
        ApiKeySlot.miniMax => 'language_coach.api_key.miniMax',
        ApiKeySlot.deepSeek => 'language_coach.api_key.deepseek',
      };
}
