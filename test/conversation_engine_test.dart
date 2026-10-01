import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/conversation_engine.dart';
import 'package:language_coach/core/model/app_settings.dart';
import 'package:language_coach/core/model/chat_models.dart';

void main() {
  final engine = ConversationEngine(settings: AppSettings());

  test('detects core intents', () {
    expect(engine.detectIntent('为什么这里用 raining？'), CoachIntent.grammarQuestion);
    expect(engine.detectIntent('今天下雨怎么用英语表达？'), CoachIntent.expressionHelp);
    expect(engine.detectIntent('和我模拟酒店入住'), CoachIntent.roleplay);
  });
}
