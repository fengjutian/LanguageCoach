import 'package:flutter/services.dart';

/// Opens this application's page in the host operating system settings.
class AppSettings {
  AppSettings._();

  static const MethodChannel _commands =
      MethodChannel('language_coach/ai_commands');

  static Future<void> open() =>
      _commands.invokeMethod<void>('openAppSettings');
}
