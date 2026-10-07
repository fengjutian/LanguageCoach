import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/asr_engine.dart';
import '../../../core/audio/asr_model_profile.dart';
import '../../../core/native/native_ai_bridge.dart';
import 'conversation_providers.dart';

/// Stream the ASR engine is listening on. Backed by the Kotlin side
/// until P1-5 swaps in a sherpa-onnx JNI library; until then the engine
/// only emits error events when the model isn't installed.
///
/// Decodes only `ASR_PARTIAL` / `ASR_FINAL` / `ASR_ERROR` — lifecycle
/// events (`ASR_START` etc.) are handled inside
/// [SpeechSessionController] so they don't surface as fake failures.
final asrResultStreamProvider = StreamProvider<AsrResult>((ref) {
  return ref
      .watch(nativeAiBridgeProvider)
      .eventStream
      .map((event) => event?.toAsrResult())
      .where((result) => result != null)
      .cast<AsrResult>();
});

/// Settings-side knob: which ASR input language to use. Distinct from
/// the coach target language — a user learning English might prefer to
/// dictate in Mandarin. `null` means "no explicit choice"; see
/// [resolvedAsrLanguageProvider] for what that resolves to.
class AsrInputLanguageController extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) {
    state = value;
  }
}

final asrInputLanguageProvider =
    NotifierProvider<AsrInputLanguageController, String?>(
  AsrInputLanguageController.new,
);

/// Sentinel meaning "let the engine auto-detect the spoken language".
const String kAsrLanguageAuto = 'auto';

/// Computed language the runtime should actually pass to the ASR engine.
///
/// The default is `auto`, *not* the coach target language. A learner who
/// switched the target to Japanese and then dictates a Chinese question was
/// previously transcribed with a Japanese model, which mangled the input.
/// Dictation is what the user says; the target language is what we answer in
/// — those are independent choices.
final resolvedAsrLanguageProvider = Provider<String>((ref) {
  final explicit = ref.watch(asrInputLanguageProvider);
  if (explicit != null && explicit.isNotEmpty) return explicit;
  return kAsrLanguageAuto;
});

/// ASR engine selection. P1-4 only knows `auto` (system SpeechRecognizer)
/// and `sherpa-onnx` (native, not yet implemented). When the runtime
/// ships the JNI binary the latter becomes the default.
class AsrEngineChoiceController extends Notifier<AsrEngineChoice> {
  @override
  AsrEngineChoice build() => AsrEngineChoice.auto;

  void set(AsrEngineChoice value) {
    state = value;
  }
}

enum AsrEngineChoice { auto, sherpaOnnx, system }

final asrEngineChoiceProvider =
    NotifierProvider<AsrEngineChoiceController, AsrEngineChoice>(
  AsrEngineChoiceController.new,
);

/// State surface for the speech session — the chat UI reads this to know
/// when to swap the mic icon, when to push a partial result into the
/// composer, and when to surface an error toast.
class SpeechSessionState {
  const SpeechSessionState({
    required this.listening,
    required this.partialText,
    required this.lastError,
    required this.lastErrorMessage,
    required this.engineReady,
    required this.activeProfile,
  });

  final bool listening;
  final String partialText;
  final AsrErrorKind? lastError;

  /// Native detail string for [lastError]. Surfaced to the chat page so
  /// it can format a useful toast instead of a generic "voice failed".
  final String? lastErrorMessage;
  final bool engineReady;
  final AsrModelProfile? activeProfile;

  SpeechSessionState copyWith({
    bool? listening,
    String? partialText,
    AsrErrorKind? lastError,
    String? lastErrorMessage,
    bool clearError = false,
    bool? engineReady,
    AsrModelProfile? activeProfile,
    bool clearActiveProfile = false,
  }) {
    return SpeechSessionState(
      listening: listening ?? this.listening,
      partialText: partialText ?? this.partialText,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastErrorMessage:
          clearError ? null : (lastErrorMessage ?? this.lastErrorMessage),
      engineReady: engineReady ?? this.engineReady,
      activeProfile:
          clearActiveProfile ? null : (activeProfile ?? this.activeProfile),
    );
  }

  static const initial = SpeechSessionState(
    listening: false,
    partialText: '',
    lastError: null,
    lastErrorMessage: null,
    engineReady: false,
    activeProfile: null,
  );
}

final speechSessionControllerProvider =
    NotifierProvider<SpeechSessionController, SpeechSessionState>(
  SpeechSessionController.new,
);

class SpeechSessionController extends Notifier<SpeechSessionState> {
  // Read the current engine choice on demand from the mutation methods —
  // using `ref.watch` here would tie the choice to the notifier's
  // dependency graph and re-emit a rebuild every time the user toggled
  // the engine in settings, which `Notifier`'s API doesn't support.
  AsrEngineChoice _readEngine() => ref.read(asrEngineChoiceProvider);

  @override
  SpeechSessionState build() {
    // Subscribe directly to the bridge so we own the full ASR surface
    // (transcript frames + lifecycle events). Previously this came via
    // `asrResultStreamProvider`, which decoded every unknown frame as
    // an `AsrFailure` — that made `ASR_START` show up as a fake error.
    final sub = ref.read(nativeAiBridgeProvider).eventStream.listen(_onFrame);
    ref.onDispose(sub.cancel);
    return SpeechSessionState.initial;
  }

  void _onFrame(Object? frame) {
    if (frame is! Map) return;
    final type = frame['type'];
    if (type is! String) return;
    // Lifecycle events drive the listening flag without producing a
    // transcript. They also close the race between
    // `bridge.startListening()` returning and the platform actually
    // beginning capture.
    switch (type) {
      case 'ASR_START':
      case 'ASR_READY':
      case 'ASR_SPEECH_START':
        if (!state.listening) {
          state = state.copyWith(listening: true);
        }
        return;
      case 'ASR_CANCELLED':
        // The `listening` guard must only gate the flag. If an
        // AsrFailure/AsrFinal already flipped it false, the stale partial
        // was never cleared and the composer kept mirroring it — so a
        // cancelled utterance could still be sent as a real message.
        state = state.copyWith(
          listening: false,
          partialText: '',
        );
        return;
    }
    final result = frame.toAsrResult();
    if (result != null) _onResult(result);
  }

  /// Resolve the language the user is speaking in. Distinct from the
  /// coach target language — callers should pass
  /// [resolvedAsrLanguageProvider] rather than the coach preference.
  Future<void> start() async {
    final bridge = ref.read(nativeAiBridgeProvider);
    final language = ref.read(resolvedAsrLanguageProvider);
    try {
      if (_readEngine() == AsrEngineChoice.system ||
          _readEngine() == AsrEngineChoice.auto) {
        await bridge.startListening(language: language);
      } else {
        await bridge.startAsrCapture(preferredAsrLanguage: language);
      }
      state = state.copyWith(
        listening: true,
        partialText: '',
        clearError: true,
      );
    } catch (_) {
      // Bridge refused the capture (missing model, no permission,
      // platform-channel failure, etc.). Flip listening back off and
      // surface an unknown error — the previous version set
      // `listening: true` before awaiting the bridge, which left the
      // UI stuck in the "listening" state with no capture actually
      // running when the platform call threw.
      state = state.copyWith(
        listening: false,
        lastError: AsrErrorKind.unknown,
        // Never leave the *previous* failure's native detail paired with the
        // new `unknown` kind — the UI renders kind + message together.
        lastErrorMessage: '无法启动语音识别。',
      );
      rethrow;
    }
  }

  Future<void> stop() async {
    final bridge = ref.read(nativeAiBridgeProvider);
    try {
      if (_readEngine() == AsrEngineChoice.system ||
          _readEngine() == AsrEngineChoice.auto) {
        await bridge.stopListening();
      } else {
        await bridge.stopAsrCapture();
      }
      state = state.copyWith(listening: false, partialText: '');
    } catch (_) {
      state = state.copyWith(listening: false);
    }
  }

  Future<void> cancel() async {
    final bridge = ref.read(nativeAiBridgeProvider);
    try {
      if (_readEngine() == AsrEngineChoice.system ||
          _readEngine() == AsrEngineChoice.auto) {
        await bridge.cancelListening();
      } else {
        await bridge.cancelAsrCapture();
      }
    } catch (_) {
      // Best-effort — the local state still flips back to idle so the
      // UI can recover even if the platform channel is unresponsive.
    }
    state = state.copyWith(listening: false, partialText: '');
  }

  /// Attempt to load the best-fit ASR profile for the resolved language.
  /// Returns `true` if a profile is now resident, `false` if the model is
  /// missing (UI should prompt the user to download).
  Future<bool> ensureEngineReady() async {
    final bridge = ref.read(nativeAiBridgeProvider);
    final language = ref.read(resolvedAsrLanguageProvider);
    if (_readEngine() == AsrEngineChoice.system) {
      final ok = await bridge.isSpeechRecognitionAvailable();
      state = state.copyWith(engineReady: ok);
      return ok;
    }
    if (language == kAsrLanguageAuto) {
      // Auto-detection is a system-recognizer capability. The bundled
      // sherpa-onnx profiles are single-language, so handing them `auto`
      // made `bestFit` return null and dictation silently failed for every
      // user who had not picked an explicit input language. Route `auto` to
      // the system engine, which is the one that can actually decide.
      final ok = await bridge.isSpeechRecognitionAvailable();
      state = state.copyWith(engineReady: ok, clearActiveProfile: true);
      return ok;
    }
    if (_readEngine() == AsrEngineChoice.sherpaOnnx) {
      try {
        final raw = await bridge.listAsrProfiles();
        final installed = decodeAsrProfiles(raw);
        final profile = bestFit(language, installed);
        if (profile == null) {
          state = state.copyWith(engineReady: false);
          return false;
        }
        final ok = await bridge.loadAsrProfile(
          profileId: profile.id,
          languageCode: language,
        );
        state = state.copyWith(
          engineReady: ok,
          activeProfile: ok ? profile : null,
          clearActiveProfile: !ok,
        );
        return ok;
      } catch (_) {
        state = state.copyWith(engineReady: false);
        return false;
      }
    }
    // auto: try sherpa first, then fall back to system. Persist the
    // resolution back into the provider so subsequent reads (and a UI
    // indicator) reflect what actually got selected.
    final sherpa = await _trySherpa(language, bridge);
    if (sherpa.ok) {
      ref
          .read(asrEngineChoiceProvider.notifier)
          .set(AsrEngineChoice.sherpaOnnx);
      // Without this the engine reported itself ready while `engineReady`
      // stayed false, so the readiness indicator never lit up.
      state = state.copyWith(
        engineReady: true,
        activeProfile: sherpa.profile,
      );
      return true;
    }
    final systemOk = await bridge.isSpeechRecognitionAvailable();
    ref.read(asrEngineChoiceProvider.notifier).set(AsrEngineChoice.system);
    state = state.copyWith(
      engineReady: systemOk,
      clearActiveProfile: true,
    );
    return systemOk;
  }

  /// Never throws: the bridge call can raise `PlatformException` when the
  /// native side is missing or torn down, and an escaping error would kill
  /// `ensureEngineReady`'s bool contract and skip the system fallback.
  Future<_SherpaAttempt> _trySherpa(
      String language, NativeAiBridge bridge) async {
    try {
      final raw = await bridge.listAsrProfiles();
      final installed = decodeAsrProfiles(raw);
      final profile = bestFit(language, installed);
      if (profile == null) return const _SherpaAttempt(false, null);
      final ok = await bridge.loadAsrProfile(
        profileId: profile.id,
        languageCode: language,
      );
      return _SherpaAttempt(ok, ok ? profile : null);
    } catch (_) {
      return const _SherpaAttempt(false, null);
    }
  }

  void _onResult(AsrResult result) {
    switch (result) {
      case AsrPartial(:final text):
        // Clear the previous error: `chatSessionPhaseProvider` checks
        // `lastError` *before* `listening`, so a stale error kept the mic
        // replaced by a retry card even while capture was working again.
        state = state.copyWith(partialText: text, clearError: true);
      case AsrFinal(:final text):
        state = state.copyWith(
          partialText: text,
          listening: false,
          clearError: true,
        );
      case AsrFailure(:final kind, :final message):
        state = state.copyWith(
          listening: false,
          lastError: kind,
          lastErrorMessage: message,
        );
    }
  }
}

/// Result of attempting to bring up the sherpa-onnx engine in `auto` mode.
class _SherpaAttempt {
  const _SherpaAttempt(this.ok, this.profile);
  final bool ok;
  final AsrModelProfile? profile;
}
