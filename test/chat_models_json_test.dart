import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/models/chat_models.dart';

void main() {
  test('CoachResponse preserves the Simplified-Chinese translation', () {
    final response = CoachResponse.fromJson(<String, Object?>{
      'intent': 'conversation',
      'targetLanguage': 'ja',
      'primary': '今日は雨です。',
      'chineseTranslation': '今天下雨。',
      'explanation': '日语说明',
    });

    expect(response.chineseTranslation, '今天下雨。');
    expect(
      CoachResponse.fromJson(response.toJson()).chineseTranslation,
      '今天下雨。',
    );
  });

  group('CoachResponse.fromJson', () {
    test('round-trips a canonical payload', () {
      const json = <String, Object?>{
        'intent': 'translation',
        'sourceLanguage': 'zh',
        'targetLanguage': 'en',
        'primary': "It's raining today.",
        'alternatives': ['It is raining.'],
        'explanation': 'Simple present progressive.',
        'sentences': [
          {'id': 's1', 'text': "It's raining today."},
        ],
        'keywords': ['rain'],
      };
      final response = CoachResponse.fromJson(json);
      expect(response.intent, CoachIntent.translation);
      expect(response.primary, "It's raining today.");
      expect(response.alternatives.single, 'It is raining.');
      expect(response.sentences.single.text, "It's raining today.");

      final back = response.toJson();
      expect(back['intent'], 'translation');
      expect(back['primary'], "It's raining today.");
    });

    test('falls back to conversation on unknown intent', () {
      final response = CoachResponse.fromJson({
        'intent': 'gibberish-not-a-real-intent',
        'primary': 'hi',
      });
      expect(response.intent, CoachIntent.conversation);
    });

    test('auto-populates sentences from primary when missing', () {
      final response = CoachResponse.fromJson({
        'intent': 'conversation',
        'primary': 'Bon anniversaire !',
      });
      expect(response.sentences, hasLength(1));
      expect(response.sentences.single.text, 'Bon anniversaire !');
      expect(response.sentences.single.id, 'auto_1');
    });

    test('keeps sentences empty when primary is empty', () {
      final response = CoachResponse.fromJson(<String, Object?>{
        'intent': 'conversation',
      });
      expect(response.primary, '');
      expect(response.sentences, isEmpty);
    });

    test('drops non-string entries from list fields', () {
      final response = CoachResponse.fromJson({
        'intent': 'conversation',
        'primary': 'x',
        'alternatives': ['ok', 42, null, 'fine'],
        'keywords': ['a', 1, 'b'],
      });
      expect(response.alternatives, ['ok', 'fine']);
      expect(response.keywords, ['a', 'b']);
    });

    test('silently handles completely empty payload', () {
      final response = CoachResponse.fromJson(const <String, Object?>{});
      expect(response.intent, CoachIntent.conversation);
      expect(response.primary, '');
      expect(response.sentences, isEmpty);
    });
  });

  group('CoachSentence.fromJson', () {
    test('accepts a map', () {
      final s = CoachSentence.fromJson({'id': 'x', 'text': 'hi'});
      expect(s.id, 'x');
      expect(s.text, 'hi');
    });

    test('accepts a bare string with hash id', () {
      final s = CoachSentence.fromJson('hello');
      expect(s.text, 'hello');
      expect(s.id, 's_${'hello'.hashCode}');
    });

    test('returns empty sentence for garbage', () {
      final s = CoachSentence.fromJson(12345);
      expect(s.id, 's_empty');
      expect(s.text, '');
    });
  });

  group('ChatMessage.fromJson', () {
    test('falls back to user on unknown role', () {
      final msg = ChatMessage.fromJson({
        'id': 'm',
        'role': 'wizard',
        'createdAt': '2026-01-01T00:00:00Z',
      });
      expect(msg.role, MessageRole.user);
      expect(msg.createdAt, DateTime.utc(2026));
    });

    test('hydrates nested response', () {
      final msg = ChatMessage.fromJson({
        'id': 'm',
        'role': 'assistant',
        'createdAt': '2026-01-01T00:00:00Z',
        'response': {
          'intent': 'translation',
          'primary': 'hola',
        },
      });
      expect(msg.response, isNotNull);
      expect(msg.response!.primary, 'hola');
    });

    test('handles invalid createdAt by using now-ish', () {
      final msg = ChatMessage.fromJson({
        'id': 'm',
        'role': 'user',
        'createdAt': 'not-a-date',
      });
      expect(
          msg.createdAt
              .isBefore(DateTime.now().add(const Duration(seconds: 5))),
          isTrue);
    });
  });
}
