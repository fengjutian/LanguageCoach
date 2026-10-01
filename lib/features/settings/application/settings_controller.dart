import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:language_coach/core/models/app_settings.dart';

/// Single source of truth for [AppSettings]. UI components watch this
/// provider; mutations go through the [SettingsController] so widgets never
/// touch a mutable instance directly. Persistence (SQLite in P0-3) plugs in
/// here without touching call-sites.
final settingsControllerProvider =
    NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => AppSettings.defaults;

  /// Replace the current settings wholesale — used by SQLite hydration during
  /// P0-3 startup.
  void replace(AppSettings next) {
    state = next;
  }

  /// Apply a JSON-shaped snapshot — defensive against partially populated
  /// payloads from disk.
  void hydrateFromJson(Map<Object?, Object?> raw) {
    state = AppSettings.fromJson(raw);
  }

  void setPreferredLanguage(CoachLanguage value) {
    state = state.copyWith(preferredLanguage: value);
  }

  void setProvider(AiProvider value) {
    state = state.copyWith(provider: value);
  }

  void setSpeechSpeed(double value) {
    state = state.copyWith(speechSpeed: value);
  }

  void setAutoPlay(bool value) {
    state = state.copyWith(autoPlay: value);
  }

  void setSaveHistory(bool value) {
    state = state.copyWith(saveHistory: value);
  }
}
