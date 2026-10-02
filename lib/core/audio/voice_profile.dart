import '../models/app_settings.dart';

/// One selectable voice for a given target language. The catalog lives
/// next to the model manifests because P2-5 will use them interchangeably
/// — the TTS engine should be able to ask "what voices do I have for
/// `CoachLanguage.english`?" and get back a stable list.
class VoiceProfile {
  const VoiceProfile({
    required this.id,
    required this.language,
    required this.label,
    this.gender = VoiceGender.neutral,
    this.sampleRef,
    this.notes,
  });

  /// Stable identifier — e.g. `en_us_female_warm`. Sent to the TTS engine
  /// verbatim so the runtime can look up the on-device voice.
  final String id;

  /// Target language this voice speaks. The catalog keeps voices for
  /// every supported [CoachLanguage] and the UI groups them by language.
  final CoachLanguage language;

  /// Human-readable label, e.g. `Warm female (US)`. Rendered in the picker.
  final String label;

  /// Coarse gender label. P2-5 doesn't try to be exhaustive — neutral is
  /// the default and the UI doesn't surface a label for it.
  final VoiceGender gender;

  /// Optional URI / asset path to a small audio sample the chat page can
  /// play when the user taps a voice preview button. `null` until the
  /// catalog ships with samples.
  final String? sampleRef;

  /// Free-form note surfaced in the picker tooltip (e.g. `Slower pace`).
  final String? notes;
}

enum VoiceGender { neutral, female, male, other }

/// Curated voice catalog. P2-5 only carries the bare minimum — one
/// neutral default per language — so the picker always has something to
/// show. Production overrides this list with a manifest-style JSON load
/// once voices ship on the native side.
const List<VoiceProfile> voiceCatalog = <VoiceProfile>[
  VoiceProfile(
    id: 'en_us_neutral',
    language: CoachLanguage.english,
    label: 'Default (US)',
  ),
  VoiceProfile(
    id: 'en_us_female_warm',
    language: CoachLanguage.english,
    label: 'Warm female',
    gender: VoiceGender.female,
    notes: 'Conversational, slightly slower pace.',
  ),
  VoiceProfile(
    id: 'ja_jp_neutral',
    language: CoachLanguage.japanese,
    label: 'Default (JP)',
  ),
  VoiceProfile(
    id: 'fr_fr_neutral',
    language: CoachLanguage.french,
    label: 'Default (FR)',
  ),
  VoiceProfile(
    id: 'ko_kr_neutral',
    language: CoachLanguage.korean,
    label: 'Default (KR)',
  ),
  VoiceProfile(
    id: 'es_es_neutral',
    language: CoachLanguage.spanish,
    label: 'Default (ES)',
  ),
  VoiceProfile(
    id: 'de_de_neutral',
    language: CoachLanguage.german,
    label: 'Default (DE)',
  ),
  VoiceProfile(
    id: 'it_it_neutral',
    language: CoachLanguage.italian,
    label: 'Default (IT)',
  ),
  VoiceProfile(
    id: 'zh_cn_neutral',
    language: CoachLanguage.chinese,
    label: 'Default (中文)',
  ),
  VoiceProfile(
    id: 'ru_ru_neutral',
    language: CoachLanguage.russian,
    label: 'Default (RU)',
  ),
  VoiceProfile(
    id: 'pt_br_neutral',
    language: CoachLanguage.portuguese,
    label: 'Default (PT)',
  ),
];

/// Returns every voice available for [language], sorted with the
/// language default first.
List<VoiceProfile> voicesFor(CoachLanguage language) {
  final all = voiceCatalog.where((v) => v.language == language).toList();
  all.sort((a, b) {
    final aIsDefault = a.id.endsWith('_neutral');
    final bIsDefault = b.id.endsWith('_neutral');
    if (aIsDefault != bIsDefault) return aIsDefault ? -1 : 1;
    return a.label.compareTo(b.label);
  });
  return all;
}

VoiceProfile? voiceById(String id) {
  for (final v in voiceCatalog) {
    if (v.id == id) return v;
  }
  return null;
}

VoiceProfile defaultVoiceFor(CoachLanguage language) {
  final all = voicesFor(language);
  if (all.isEmpty) {
    // Defensive — should never happen since the catalog covers every
    // language. Fall back to the English default so the runtime always
    // has *some* voice id to pass.
    return voiceCatalog.first;
  }
  return all.first;
}
