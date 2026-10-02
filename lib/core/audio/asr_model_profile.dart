/// One installable ASR model. The runtime picks one based on the user's
/// current ASR input language (which is *not* the same as the coach
/// target language — a user learning English might speak Mandarin to the
/// app, or vice versa).
class AsrModelProfile {
  const AsrModelProfile({
    required this.id,
    required this.languageCode,
    required this.label,
    required this.sizeBytes,
    required this.accuracyTier,
    this.transducer = 'whisper',
    this.notes,
  });

  /// Stable identifier — e.g. `sherpa-onnx-streaming-zh-en-small`.
  final String id;

  /// BCP-47 style language tag the model understands, e.g. `zh-CN` /
  /// `en-US`. Used by the UI to map a user's "ASR input language" choice
  /// onto a concrete profile.
  final String languageCode;

  /// Human-readable label surfaced in the model manager UI.
  final String label;

  /// Decompressed footprint on disk.
  final int sizeBytes;

  /// Coarse accuracy tier — used by [bestFit] to pick the closest installed
  /// model when an exact language match is unavailable.
  final AccuracyTier accuracyTier;

  /// Backend implementation: `whisper` / `zipformer` / `conformer`. P1-4
  /// wires only sherpa-onnx; the field exists so a future LLM-based ASR
  /// doesn't need a separate profile type.
  final String transducer;

  final String? notes;

  bool get isStreaming => transducer != 'whisper';
}

enum AccuracyTier { small, medium, large }

/// Curated list of profiles the runtime ships with. P1-5 publishes real
/// downloads; P1-4 only needs the metadata to drive the UI / router.
const _kAsrProfiles = <AsrModelProfile>[
  AsrModelProfile(
    id: 'sherpa-onnx-zipformer-zh-small',
    languageCode: 'zh-CN',
    label: '普通话 · 小',
    sizeBytes: 0,
    accuracyTier: AccuracyTier.small,
    transducer: 'zipformer',
  ),
  AsrModelProfile(
    id: 'sherpa-onnx-zipformer-en-small',
    languageCode: 'en-US',
    label: 'English · Small',
    sizeBytes: 0,
    accuracyTier: AccuracyTier.small,
    transducer: 'zipformer',
  ),
  AsrModelProfile(
    id: 'sherpa-onnx-zipformer-ja-small',
    languageCode: 'ja-JP',
    label: '日本語 · 小',
    sizeBytes: 0,
    accuracyTier: AccuracyTier.small,
    transducer: 'zipformer',
  ),
  AsrModelProfile(
    id: 'sherpa-onnx-zipformer-zh-medium',
    languageCode: 'zh-CN',
    label: '普通话 · 中',
    sizeBytes: 0,
    accuracyTier: AccuracyTier.medium,
    transducer: 'zipformer',
  ),
];

/// Returns every profile known to the runtime, regardless of install state.
List<AsrModelProfile> knownAsrProfiles() => List.unmodifiable(_kAsrProfiles);

/// Pick the best installed profile for [languageCode] out of [installed].
/// Returns `null` when no profile matches the requested language, so the
/// caller can prompt the user to download the right one. Cross-language
/// fallback is deliberately rejected: feeding a Mandarin model a
/// Japanese speaker produced garbage text, which is worse than a visible
/// "model not installed" error.
AsrModelProfile? bestFit(
  String languageCode,
  Iterable<AsrModelProfile> installed,
) {
  if (installed.isEmpty) return null;
  final exact = installed.where((p) => p.languageCode == languageCode).toList();
  if (exact.isEmpty) return null;
  exact.sort((a, b) => b.accuracyTier.index.compareTo(a.accuracyTier.index));
  return exact.first;
}
