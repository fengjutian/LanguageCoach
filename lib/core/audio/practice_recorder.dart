import 'package:flutter/services.dart';

abstract interface class PracticeRecorder {
  Future<void> start();
  Future<String?> stop();
  Future<void> cancel();
}

class AndroidPracticeRecorder implements PracticeRecorder {
  const AndroidPracticeRecorder();
  static const _channel = MethodChannel('language_coach/ai_commands');

  @override
  Future<void> start() => _channel.invokeMethod<void>('startPracticeRecording');

  @override
  Future<String?> stop() =>
      _channel.invokeMethod<String>('stopPracticeRecording');

  @override
  Future<void> cancel() =>
      _channel.invokeMethod<void>('cancelPracticeRecording');
}

class InMemoryPracticeRecorder implements PracticeRecorder {
  String? nextPath;
  bool recording = false;
  @override
  Future<void> start() async => recording = true;
  @override
  Future<String?> stop() async {
    recording = false;
    return nextPath;
  }

  @override
  Future<void> cancel() async => recording = false;
}
