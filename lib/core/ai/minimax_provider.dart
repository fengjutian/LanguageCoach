import 'package:language_coach/core/ai/openai_compatible_provider.dart';
import 'package:language_coach/core/config/app_config.dart';
import 'package:language_coach/core/network/api_client.dart';

class MiniMaxProvider extends OpenAiCompatibleProvider {
  MiniMaxProvider({
    required super.endpoint,
    required super.apiKeyResolver,
    required super.apiClient,
  }) : super(id: 'MiniMax');
}

class DeepSeekProvider extends OpenAiCompatibleProvider {
  DeepSeekProvider({
    required super.endpoint,
    required super.apiKeyResolver,
    required super.apiClient,
  }) : super(id: 'DeepSeek');
}