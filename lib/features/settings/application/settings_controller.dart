import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database_provider.dart';
import '../../../core/models/app_settings.dart';

/// Single source of truth for [AppSettings]. UI components watch this
/// provider; mutations go through the [SettingsController] so widgets never
/// touch a mutable instance directly. Every setter persists to SQLite via
/// [settingsRepositoryProvider] in the background.
final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => AppSettings.defaults;

  Future<void> _persist() async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveRaw(state.toJson());
  }

  /// Replace the current settings wholesale — used by SQLite hydration during
  /// P0-3 startup. Persists the new value.
  Future<void> replace(AppSettings next) async {
    state = next;
    await _persist();
  }

  /// Apply a JSON-shaped snapshot — defensive against partially populated
  /// payloads from disk. Used by tests that bypass the SQLite layer.
  Future<void> hydrateFromJson(Map<Object?, Object?> raw) async {
    state = AppSettings.fromJson(raw);
  }

  void setPreferredLanguage(CoachLanguage value) {
    state = state.copyWith(preferredLanguage: value);
    unawaited(_persist());
  }

  void setProvider(AiProvider value) {
    state = state.copyWith(provider: value);
    unawaited(_persist());
  }

  void setSpeechSpeed(double value) {
    state = state.copyWith(speechSpeed: value);
    unawaited(_persist());
  }

  void setAutoPlay(bool value) {
    state = state.copyWith(autoPlay: value);
    unawaited(_persist());
  }

  void setSaveHistory(bool value) {
    state = state.copyWith(saveHistory: value);
    unawaited(_persist());
  }

  void setLastConversationId(String? id) {
    state = state.copyWith(
      lastConversationId: id,
      clearLastConversationId: id == null,
    );
    unawaited(_persist());
  }
}
