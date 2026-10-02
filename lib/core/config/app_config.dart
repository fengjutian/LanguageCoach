import 'package:flutter/foundation.dart';

/// Per-provider endpoint & model configuration. Tests inject a custom
/// instance via the [appConfigProvider]; production code reads from
/// `lib/core/config/app_config.dart` defaults. Nothing in this file may
/// contain real API keys or account-bound paths.
@immutable
class AppConfig {
  const AppConfig({
    required this.miniMax,
    required this.deepSeek,
    required this.requestTimeout,
  });

  /// Default configuration targeting the public OpenAI-compatible surfaces.
  /// All values are overridable so a CI test or a future build flavour can
  /// point at a different host without code edits.
  static const defaultAppConfig = AppConfig(
    miniMax: ProviderEndpoint(
      baseUrl: 'https://api.minimaxi.com/v1',
      model: 'MiniMax-M3',
    ),
    deepSeek: ProviderEndpoint(
      baseUrl: 'https://api.deepseek.com/v1',
      model: 'deepseek-chat',
    ),
    requestTimeout: Duration(seconds: 30),
  );

  final ProviderEndpoint miniMax;
  final ProviderEndpoint deepSeek;
  final Duration requestTimeout;
}

@immutable
class ProviderEndpoint {
  const ProviderEndpoint({required this.baseUrl, required this.model});
  final String baseUrl;
  final String model;
}
