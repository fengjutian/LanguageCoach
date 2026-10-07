import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Inputs to the text-to-speech pipeline. Stable identifier fields so the
/// audio cache can key on (text, language, voice, speed, model) without
/// re-synthesising identical requests.
class TtsRequest {
  const TtsRequest({
    required this.text,
    required this.language,
    this.voiceId = 'default',
    this.speed = 1.0,
    this.emotion = 'neutral',
    this.modelVersion = 'system',
  });

  final String text;
  final String language;
  final String voiceId;
  final double speed;
  final String emotion;
  final String modelVersion;

  /// Stable cache key. Same request -> same digest, regardless of object
  /// identity. SHA-1 is fine here — collisions would merely trigger a cache
  /// miss, not data corruption.
  ///
  /// The text is hashed with SHA-1 rather than `String.hashCode`: Dart's
  /// `hashCode` is randomised per process, so every app launch derived a
  /// *different* key for the same request, the on-disk cache could never hit
  /// and each launch wrote a fresh copy of every synthesized file.
  String cacheKey() {
    return sha1.convert(utf8.encode(
      '$language|$voiceId|$speed|$emotion|$modelVersion|$text',
    )).toString();
  }

  /// Filesystem-safe, process-stable base name for this request's audio.
  String cacheFileBaseName() => cacheKey();

  TtsRequest copyWith({
    String? text,
    String? language,
    String? voiceId,
    double? speed,
    String? emotion,
    String? modelVersion,
  }) {
    return TtsRequest(
      text: text ?? this.text,
      language: language ?? this.language,
      voiceId: voiceId ?? this.voiceId,
      speed: speed ?? this.speed,
      emotion: emotion ?? this.emotion,
      modelVersion: modelVersion ?? this.modelVersion,
    );
  }
}

/// Output of a single TTS synthesis. [audioPath] is an absolute path on
/// disk; [duration] is best-effort and may be null when the runtime cannot
/// report timing before playback.
class TtsResult {
  const TtsResult({
    required this.audioPath,
    this.duration,
    this.bytes,
    this.format,
  });
  final String audioPath;
  final Duration? duration;
  final int? bytes;
  final String? format;
}

/// Errors raised by TTS implementations. Surfaced as [TtsErrorKind] so the
/// UI can render a localised message without parsing free text.
enum TtsErrorKind { engineUnavailable, network, format, cancelled, unknown }

class TtsError implements Exception {
  const TtsError(this.kind, this.message);
  final TtsErrorKind kind;
  final String message;
  @override
  String toString() => 'TtsError($kind, $message)';
}
