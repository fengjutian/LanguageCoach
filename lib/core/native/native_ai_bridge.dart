import 'package:flutter/services.dart';

/// Stable Flutter boundary for the Kotlin Native AI Core.
/// Commands use MethodChannel; streaming ASR/LLM/TTS events use EventChannel.
///
/// The interface lives here so tests can drop in a [FakeNativeAiBridge]
/// without binding to the platform side; production code uses
/// [DefaultBridge] which delegates to [MethodChannel] / [EventChannel].
abstract interface class NativeAiBridge {
  Stream<Object?> get eventStream;

  Future<Map<Object?, Object?>?> generate({
    required String prompt,
    required String model,
  });

  Future<String?> synthesize({
    required String text,
    required String language,
    String voice,
    double speed,
  });

  Future<bool> isSpeechRecognitionAvailable();

  Future<void> startListening({required String language});
  Future<void> stopListening();
  Future<void> cancelListening();
}

/// Production bridge backed by the platform channels defined on the Android
/// side in `MainActivity.kt`. Replace in tests with any other
/// [NativeAiBridge] implementation.
class DefaultBridge implements NativeAiBridge {
  const DefaultBridge();

  static const MethodChannel _commands =
      MethodChannel('language_coach/ai_commands');
  static const EventChannel _events =
      EventChannel('language_coach/ai_events');

  @override
  Stream<Object?> get eventStream => _events.receiveBroadcastStream();

  @override
  Future<Map<Object?, Object?>?> generate({
    required String prompt,
    required String model,
  }) =>
      _commands.invokeMapMethod('generate', {'prompt': prompt, 'model': model});

  @override
  Future<String?> synthesize({
    required String text,
    required String language,
    String voice = 'default',
    double speed = 1,
  }) =>
      _commands.invokeMethod<String>('synthesize', {
        'text': text,
        'language': language,
        'voice': voice,
        'speed': speed,
      });

  @override
  Future<bool> isSpeechRecognitionAvailable() async =>
      await _commands.invokeMethod<bool>('isSpeechRecognitionAvailable') ??
      false;

  @override
  Future<void> startListening({required String language}) =>
      _commands.invokeMethod<void>('startListening', {'language': language});

  @override
  Future<void> stopListening() => _commands.invokeMethod<void>('stopListening');

  @override
  Future<void> cancelListening() =>
      _commands.invokeMethod<void>('cancelListening');
}