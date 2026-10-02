import 'package:flutter/foundation.dart';

enum AiProvider { auto, miniMax, deepSeek, localQwen }

enum CoachLanguage {
  english('en', 'English', '🇺🇸'),
  japanese('ja', '日本語', '🇯🇵'),
  french('fr', 'Français', '🇫🇷'),
  korean('ko', '한국어', '🇰🇷'),
  spanish('es', 'Español', '🇪🇸'),
  german('de', 'Deutsch', '🇩🇪'),
  italian('it', 'Italiano', '🇮🇹'),
  chinese('zh-CN', '中文', '🇨🇳'),
  russian('ru', 'Русский', '🇷🇺'),
  portuguese('pt', 'Português', '🇵🇹');

  const CoachLanguage(this.code, this.label, this.flag);
  final String code;
  final String label;
  final String flag;
}

/// Immutable user-facing settings. All mutations happen via a Riverpod notifier
/// so the UI never holds a [ChangeNotifier] directly (see
/// [SettingsController]). The model also round-trips through JSON so it can
/// be persisted in SQLite during P0-3.
@immutable
class AppSettings {
  const AppSettings({
    required this.preferredLanguage,
    required this.provider,
    required this.speechSpeed,
    required this.autoPlay,
    required this.saveHistory,
    this.lastConversationId,
    this.selectedVoices = const <CoachLanguage, String>{},
  });

  final CoachLanguage preferredLanguage;
  final AiProvider provider;
  final double speechSpeed;
  final bool autoPlay;
  final bool saveHistory;

  /// Most recently visited conversation id. `null` after first install or
  /// after the user explicitly clears history. Stored in the SQLite settings
  /// table so the chat page can resume the right bubble on cold start.
  final String? lastConversationId;

  /// User-selected voice id per language. Missing entries fall back to the
  /// language default at the point of use (TTS request builder).
  final Map<CoachLanguage, String> selectedVoices;

  /// Voice id for [language] — either the user-picked one or the language
  /// default. Pure function so widget tests + JSON round-trips can call it
  /// without dragging in the catalog.
  String voiceFor(CoachLanguage language, String defaultVoiceId) {
    return selectedVoices[language] ?? defaultVoiceId;
  }

  /// Values the audio pipeline accepts. Anything outside this set is
  /// rejected by [fromJson] / [copyWith] so the UI can never feed an invalid
  /// TTS speed downstream.
  static const List<double> allowedSpeechSpeeds = <double>[
    0.75,
    0.85,
    1.0,
    1.15,
    1.25,
    1.5,
  ];

  static const AppSettings defaults = AppSettings(
    preferredLanguage: CoachLanguage.english,
    provider: AiProvider.auto,
    speechSpeed: 1.0,
    autoPlay: false,
    saveHistory: true,
  );

  AppSettings copyWith({
    CoachLanguage? preferredLanguage,
    AiProvider? provider,
    double? speechSpeed,
    bool? autoPlay,
    bool? saveHistory,
    String? lastConversationId,
    bool clearLastConversationId = false,
    Map<CoachLanguage, String>? selectedVoices,
  }) {
    final nextSpeed = speechSpeed ?? this.speechSpeed;
    if (!allowedSpeechSpeeds.contains(nextSpeed)) {
      throw ArgumentError.value(
        nextSpeed,
        'speechSpeed',
        'must be one of $allowedSpeechSpeeds',
      );
    }
    return AppSettings(
      preferredLanguage: preferredLanguage ?? this.preferredLanguage,
      provider: provider ?? this.provider,
      speechSpeed: nextSpeed,
      autoPlay: autoPlay ?? this.autoPlay,
      saveHistory: saveHistory ?? this.saveHistory,
      lastConversationId: clearLastConversationId
          ? null
          : (lastConversationId ?? this.lastConversationId),
      selectedVoices: selectedVoices ?? this.selectedVoices,
    );
  }

  factory AppSettings.fromJson(Map<Object?, Object?> raw) {
    final languageRaw = raw['preferredLanguage'];
    final language = CoachLanguage.values.firstWhere(
      (l) => l.name == languageRaw,
      orElse: () => CoachLanguage.english,
    );

    final providerRaw = raw['provider'];
    final provider = AiProvider.values.firstWhere(
      (p) => p.name == providerRaw,
      orElse: () => AiProvider.auto,
    );

    final speedRaw = raw['speechSpeed'];
    final speedParsed = switch (speedRaw) {
      num() => speedRaw.toDouble(),
      String() => double.tryParse(speedRaw) ?? 1.0,
      _ => 1.0,
    };
    final speed = allowedSpeechSpeeds.contains(speedParsed) ? speedParsed : 1.0;

    final voicesRaw = raw['selectedVoices'];
    final selectedVoices = <CoachLanguage, String>{};
    if (voicesRaw is Map) {
      voicesRaw.forEach((key, value) {
        final lang = CoachLanguage.values.firstWhere(
          (l) => l.name == key,
          orElse: () => CoachLanguage.english,
        );
        if (value is String) selectedVoices[lang] = value;
      });
    }

    return AppSettings(
      preferredLanguage: language,
      provider: provider,
      speechSpeed: speed,
      autoPlay: raw['autoPlay'] == true,
      saveHistory: raw['saveHistory'] != false,
      lastConversationId: raw['lastConversationId']?.toString(),
      selectedVoices: selectedVoices,
    );
  }

  Map<String, Object?> toJson() => {
        'preferredLanguage': preferredLanguage.name,
        'provider': provider.name,
        'speechSpeed': speechSpeed,
        'autoPlay': autoPlay,
        'saveHistory': saveHistory,
        'lastConversationId': lastConversationId,
        'selectedVoices':
            selectedVoices.map((k, v) => MapEntry(k.name, v)),
      };
}
