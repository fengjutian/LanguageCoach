/// Declarative description of a downloadable model artifact. Lives in
/// `model_records` once downloaded; the manifest here is the source of
/// truth for *what to download*.
///
/// For Qwen3-TTS the on-device runtime consumes three files (tokenizer +
/// talker weights + decoder config) plus an optional voice profile. Each
/// artifact carries its own SHA-256 and size so the download manager can
/// verify before installing.
class ModelManifest {
  const ModelManifest({
    required this.id,
    required this.type,
    required this.version,
    required this.sizeBytes,
    required this.downloadUrl,
    required this.sha256,
    required this.artifacts,
    this.label,
    this.minimumRamMb,
    this.supportedAbis = const <String>['arm64-v8a'],
    this.notes,
  });

  /// Stable identifier — e.g. `qwen3-tts-0.6B`.
  final String id;

  /// High-level kind: `tts` / `llm` / `asr` / `vad`.
  final String type;

  /// Semver-style version tag, e.g. `0.6.0`.
  final String version;

  /// Total decompressed footprint on disk (sum of all artifact sizes).
  final int sizeBytes;

  /// Primary archive URL. May itself be a `.tar.gz` containing the
  /// [artifacts] list, in which case the download manager extracts them on
  /// the host.
  final String downloadUrl;

  /// Top-level archive checksum.
  final String sha256;

  /// Individual files contained inside the archive — checked individually
  /// after extraction.
  final List<ModelArtifact> artifacts;

  /// Human-readable display label used by the model manager UI.
  final String? label;

  /// Soft device gate. The download manager rejects installs on devices
  /// below this threshold.
  final int? minimumRamMb;

  /// Target ABIs. The runtime refuses to load if the device ABI is not in
  /// this list. First-cut is `arm64-v8a` only; P1-6 may add x86_64 for
  /// emulator dev.
  final List<String> supportedAbis;

  /// Human-readable annotation surfaced in the model manager UI.
  final String? notes;
}

class ModelArtifact {
  const ModelArtifact({
    required this.relativePath,
    required this.sizeBytes,
    required this.sha256,
    required this.role,
  });

  /// Path inside the on-device model directory.
  final String relativePath;

  final int sizeBytes;
  final String sha256;

  /// What the runtime does with this file: `tokenizer`, `talker_weights`,
  /// `decoder_config`, `voice_profile`, etc.
  final String role;
}

/// The Qwen3-LLM 0.6B manifest — the local reasoning engine that powers
/// `LocalQwenProvider` in P1-6. Layout is intentionally close to the TTS
/// manifest (tokenizer + weights + config) so the same `ModelDownloadService`
/// pipeline can install it. Real SHA-256 / URL land with the model release.
const ModelManifest qwen3Llm06B = ModelManifest(
  id: 'qwen3-llm-0.6B',
  type: 'llm',
  version: '0.6.0',
  label: 'Qwen3 LLM 0.6B (Local)',
  sizeBytes: 0,
  downloadUrl: 'https://example.invalid/qwen3-llm-0.6B.tar.gz',
  sha256: 'PLACEHOLDER_SHA256',
  minimumRamMb: 4096,
  supportedAbis: <String>['arm64-v8a'],
  notes: 'Placeholder manifest. Real SHA-256 and URL land with the model '
      'release in P1-6.',
  artifacts: <ModelArtifact>[
    ModelArtifact(
      relativePath: 'tokenizer.json',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_LLM_TOKENIZER_SHA256',
      role: 'tokenizer',
    ),
    ModelArtifact(
      relativePath: 'llm_qwen.bin',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_LLM_WEIGHTS_SHA256',
      role: 'llm_weights',
    ),
    ModelArtifact(
      relativePath: 'llm_config.json',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_LLM_CONFIG_SHA256',
      role: 'llm_config',
    ),
  ],
);

/// The Qwen3-TTS 0.6B manifest. Numbers below are placeholders — the real
/// release ships a published checksum and URL. P1-3 verifies the runtime
/// can load a manifest like this; the actual fetch lands in P1-5.
const ModelManifest qwen3Tts06B = ModelManifest(
  id: 'qwen3-tts-0.6B',
  type: 'tts',
  version: '0.6.0',
  label: 'Qwen3-TTS 0.6B',
  sizeBytes: 0,
  downloadUrl: 'https://example.invalid/qwen3-tts-0.6B.tar.gz',
  sha256: 'PLACEHOLDER_SHA256',
  minimumRamMb: 4096,
  supportedAbis: <String>['arm64-v8a'],
  notes: 'Placeholder manifest. Real SHA-256 and URL land with the model '
      'release in P1-5.',
  artifacts: <ModelArtifact>[
    ModelArtifact(
      relativePath: 'tokenizer.json',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_TOKENIZER_SHA256',
      role: 'tokenizer',
    ),
    ModelArtifact(
      relativePath: 'talker_qwen.bin',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_TALKER_SHA256',
      role: 'talker_weights',
    ),
    ModelArtifact(
      relativePath: 'decoder_config.json',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_DECODER_SHA256',
      role: 'decoder_config',
    ),
    ModelArtifact(
      relativePath: 'voices/cherry.json',
      sizeBytes: 0,
      sha256: 'PLACEHOLDER_VOICE_SHA256',
      role: 'voice_profile',
    ),
  ],
);
