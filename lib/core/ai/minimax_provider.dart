import 'package:language_coach/core/ai/openai_compatible_provider.dart';

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
