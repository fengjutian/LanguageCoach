import 'package:flutter/services.dart';

/// Stable Flutter boundary for the Kotlin Native AI Core.
/// Commands use MethodChannel; streaming ASR/LLM/TTS events use EventChannel.
class NativeAiBridge {
  const NativeAiBridge();
  static const commands = MethodChannel('language_coach/ai_commands');
  static const events = EventChannel('language_coach/ai_events');

  Future<Map<Object?, Object?>?> generate({
    required String prompt,
    required String model,
  }) =>
      commands.invokeMapMethod('generate', {'prompt': prompt, 'model': model});

  Future<String?> synthesize({
    required String text,
    required String language,
    String voice = 'default',
    double speed = 1,
  }) =>
      commands.invokeMethod<String>('synthesize', {
        'text': text,
        'language': language,
        'voice': voice,
        'speed': speed,
      });

  Stream<Object?> get eventStream => events.receiveBroadcastStream();
}
