import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/database/app_database_provider.dart';
import '../../../core/models/app_settings.dart';

/// Single source of truth for [AppSettings]. UI components watch this
/// provider; mutations go through the [SettingsController] so widgets never
/// touch a mutable instance directly. Every setter persists to SQLite via
/// [settingsRepositoryProvider] on a serialised queue.
final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

/// Last persistence failure, surfaced instead of being swallowed. Session
/// switching depends on `lastConversationId` actually landing on disk.
final settingsPersistenceErrorProvider = StateProvider<Object?>(
  (_) => null,
);

class SettingsController extends Notifier<AppSettings> {
  /// Serialises writes. Fire-and-forget `unawaited(_persist())` used to read
  /// `state` at execution time, so "切语言 → 新建会话" raced two writes with
  /// no ordering and no completion guarantee — exactly the kind of race a
  /// conversation-switch protocol cannot tolerate.
  Future<void> _writeQueue = Future<void>.value();

  @override
  AppSettings build() => AppSettings.defaults;

  /// Snapshot-and-enqueue. Each call captures the state *at call time* so the
  /// queue applies mutations in the order the user made them, and the caller
  /// can await real completion.
  Future<void> _persist() {
    final snapshot = state.toJson();
    final repo = ref.read(settingsRepositoryProvider);
    final completer = Completer<void>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        await repo.saveRaw(snapshot);
        ref.read(settingsPersistenceErrorProvider.notifier).state = null;
      } catch (e, st) {
        developer.log('settings persist failed',
            name: 'SettingsController', error: e, stackTrace: st);
        ref.read(settingsPersistenceErrorProvider.notifier).state = e;
      } finally {
        if (!completer.isCompleted) completer.complete();
      }
    });
    return completer.future;
  }

  /// Replace the current settings wholesale — used by SQLite hydration during
  /// startup. Persists the new value.
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

  /// Picks the voice id used when [language] is the active target.
  /// Stored as a per-language map so users can keep their preferred
  /// voice even after switching the default language.
  void setVoiceForLanguage(CoachLanguage language, String voiceId) {
    final next = Map<CoachLanguage, String>.from(state.selectedVoices);
    next[language] = voiceId;
    state = state.copyWith(selectedVoices: next);
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

  /// Awaitable form used by the chat controller so a conversation switch
  /// knows the pointer has been written before it reports success.
  Future<void> persistLastConversationId(String? id) async {
    setLastConversationId(id);
    await _persist();
  }
}
