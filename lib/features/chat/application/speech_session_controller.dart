import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audio/asr_engine.dart';
import '../../../core/audio/asr_model_profile.dart';
import '../../../core/native/native_ai_bridge.dart';
import '../../settings/application/settings_controller.dart';
import 'conversation_providers.dart';

/// Stream the ASR engine is listening on. Backed by the Kotlin side
/// until P1-5 swaps in a sherpa-onnx JNI library; until then the engine
/// only emits error events when the model isn't installed.
final asrResultStreamProvider = StreamProvider<AsrResult>((ref) {
  return ref.watch(nativeAiBridgeProvider).eventStream.map((event) {
    return event?.toAsrResult() ??
        AsrFailure(
          AsrErrorKind.unknown,
          'unrecognised event payload: $event',
        );
  });
});

/// Settings-side knob: which ASR input language to use. Distinct from
/// the coach target language — a user learning English might prefer to
/// dictate in Mandarin. Falls back to the coach target language when the
/// user hasn't picked one yet.
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

/// Computed language the runtime should actually pass to the ASR engine.
/// Prefers the explicit ASR input choice, then falls back to the coach
/// target language.
final resolvedAsrLanguageProvider = Provider<String>((ref) {
  final fallback = ref.watch(settingsControllerProvider).preferredLanguage.code;
  final explicit = ref.watch(asrInputLanguageProvider);
  return (explicit == null || explicit.isEmpty) ? fallback : explicit;
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
    required this.engineReady,
    required this.activeProfile,
  });

  final bool listening;
  final String partialText;
  final AsrErrorKind? lastError;
  final bool engineReady;
  final AsrModelProfile? activeProfile;

  SpeechSessionState copyWith({
    bool? listening,
    String? partialText,
    AsrErrorKind? lastError,
    bool clearError = false,
    bool? engineReady,
    AsrModelProfile? activeProfile,
    bool clearActiveProfile = false,
  }) {
    return SpeechSessionState(
      listening: listening ?? this.listening,
      partialText: partialText ?? this.partialText,
      lastError: clearError ? null : (lastError ?? this.lastError),
      engineReady: engineReady ?? this.engineReady,
      activeProfile:
          clearActiveProfile ? null : (activeProfile ?? this.activeProfile),
    );
  }

  static const initial = SpeechSessionState(
    listening: false,
    partialText: '',
    lastError: null,
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
    // Riverpod owns the subscription; this fires for every event the
    // ASR stream provider emits, including re-emits after invalidation.
    ref.listen<AsyncValue<AsrResult>>(asrResultStreamProvider, (_, next) {
      next.whenData(_onResult);
    });
    return SpeechSessionState.initial;
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
    final sherpaOk = await _trySherpa(language, bridge);
    if (sherpaOk) {
      ref.read(asrEngineChoiceProvider.notifier).set(AsrEngineChoice.sherpaOnnx);
      return true;
    }
    final systemOk = await bridge.isSpeechRecognitionAvailable();
    ref.read(asrEngineChoiceProvider.notifier).set(AsrEngineChoice.system);
    state = state.copyWith(engineReady: systemOk);
    return systemOk;
  }

  Future<bool> _trySherpa(String language, NativeAiBridge bridge) async {
    final raw = await bridge.listAsrProfiles();
    final installed = decodeAsrProfiles(raw);
    final profile = bestFit(language, installed);
    if (profile == null) return false;
    return bridge.loadAsrProfile(
      profileId: profile.id,
      languageCode: language,
    );
  }

  void _onResult(AsrResult result) {
    switch (result) {
      case AsrPartial(:final text):
        state = state.copyWith(partialText: text);
      case AsrFinal(:final text):
        state = state.copyWith(partialText: text, listening: false);
      case AsrFailure(:final kind):
        state = state.copyWith(listening: false, lastError: kind);
    }
  }
}
