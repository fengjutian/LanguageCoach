import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/ai/structured_response_parser.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/core/models/chat_models.dart';

void main() {
  const parser = StructuredResponseParser();

  CoachResponse parse(String raw) => parser.parse(
        raw,
        intent: CoachIntent.translation,
        targetLanguage: CoachLanguage.english,
      );

  test('canonical JSON without fence', () {
    const raw = '''
{
  "intent": "translation",
  "primary": "It's raining.",
  "explanation": "simple present",
  "sentences": [{"id": "x", "text": "It's raining."}]
}
''';
    final r = parse(raw);
    expect(r.intent, CoachIntent.translation);
    expect(r.primary, "It's raining.");
    expect(r.sentences.single.text, "It's raining.");
  });

  test('strips ```json fences before parsing', () {
    const raw = '''
```json
{"intent":"translation","primary":"hola","explanation":"greeting","sentences":[{"id":"a","text":"hola"}]}
```
''';
    final r = parse(raw);
    expect(r.primary, 'hola');
    expect(r.explanation, 'greeting');
  });

  test('non-JSON text becomes primary with empty explanation', () {
    final r = parse('hola amigo');
    expect(r.primary, 'hola amigo');
    expect(r.explanation, '');
    expect(r.sentences.single.text, 'hola amigo');
  });

  test('empty input returns empty primary', () {
    final r = parse('   ');
    expect(r.primary, '');
    expect(r.sentences, isEmpty);
  });

  test('missing fields fall back to defaults', () {
    final r = parse('{"primary":"hi"}');
    expect(r.primary, 'hi');
    expect(r.intent, CoachIntent.translation); // echoes request intent
    expect(r.sentences.single.text, 'hi');
  });

  test('garbage JSON does not throw', () {
    final r = parse('{not: valid json');
    expect(r.primary, '{not: valid json');
    expect(r.sentences.single.text, '{not: valid json');
  });

  test('trailing prose after fence does not break parse', () {
    const raw = '''
```json
{"primary":"hi","explanation":"hey"}
```
some trailing explanation
''';
    final r = parse(raw);
    expect(r.primary, 'hi');
  });

  test('object without primary synthesizes sentences', () {
    final r = parse('{"explanation":"just explanation"}');
    expect(r.primary, '');
    expect(r.sentences, isEmpty);
  });
}
