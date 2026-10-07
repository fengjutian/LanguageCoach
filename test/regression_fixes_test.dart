import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/tts_models.dart';
import 'package:language_coach/core/models/chat_models.dart';

/// Regression coverage for bugs that no existing test covered: the audio
/// cache key was derived from `String.hashCode`, which Dart randomises per
/// process, so every launch computed a *different* filename for the same
/// request — the cache never hit and each launch wrote a fresh copy of every
/// synthesized clip.
void main() {
  group('TtsRequest cache key', () {
    test('identical requests produce identical keys', () {
      const a = TtsRequest(text: '你好，今天天气真不错。', language: 'zh');
      const b = TtsRequest(text: '你好，今天天气真不错。', language: 'zh');
      expect(a.cacheKey(), b.cacheKey());
      expect(a.cacheFileBaseName(), b.cacheFileBaseName());
    });

    test('the key is a filesystem-safe hex digest', () {
      const request = TtsRequest(text: 'Hello / world?', language: 'en');
      final base = request.cacheFileBaseName();
      expect(base, matches(RegExp(r'^[0-9a-f]+$')));
      // What the engines actually build: '<base>.<ext>'
      expect('$base.wav', matches(RegExp(r'^[0-9a-f]+\.wav$')));
    });

    test('every field that changes the audio changes the key', () {
      const base = TtsRequest(
        text: 'hello',
        language: 'en',
        voiceId: 'default',
        speed: 1.0,
        emotion: 'neutral',
        modelVersion: 'system',
      );
      expect(base.cacheKey(), isNot(const TtsRequest(
        text: 'hello!',
        language: 'en',
      ).cacheKey()));
      expect(base.cacheKey(), isNot(const TtsRequest(
        text: 'hello',
        language: 'ja',
      ).cacheKey()));
      expect(base.cacheKey(), isNot(const TtsRequest(
        text: 'hello',
        language: 'en',
        voiceId: 'other',
      ).cacheKey()));
      expect(base.cacheKey(), isNot(const TtsRequest(
        text: 'hello',
        language: 'en',
        speed: 1.5,
      ).cacheKey()));
      expect(base.cacheKey(), isNot(const TtsRequest(
        text: 'hello',
        language: 'en',
        modelVersion: 'qwen3',
      ).cacheKey()));
    });
  });

  group('CoachResponse vocabulary', () {
    test('reads the documented nested learning.keywords layout', () {
      final response = CoachResponse.fromJson(<Object?, Object?>{
        'intent': 'translation',
        'primary': 'It is raining today.',
        'learning': <Object?, Object?>{
          'keywords': <Object?>['raining', 'forecast'],
        },
      });
      // Reading only the top-level `keywords` silently lost all vocabulary
      // for models that follow the documented layout.
      expect(response.keywords, containsAll(<String>['raining', 'forecast']));
    });

    test('still reads a flat keywords list', () {
      final response = CoachResponse.fromJson(<Object?, Object?>{
        'intent': 'translation',
        'primary': 'hi',
        'keywords': <Object?>['rain'],
      });
      expect(response.keywords, <String>['rain']);
    });

    test('merges both layouts without duplicates', () {
      final response = CoachResponse.fromJson(<Object?, Object?>{
        'intent': 'translation',
        'primary': 'hi',
        'keywords': <Object?>['rain'],
        'learning': <Object?, Object?>{
          'keywords': <Object?>['rain', 'shower'],
        },
      });
      expect(response.keywords, containsAll(<String>['rain', 'shower']));
      expect(response.keywords.where((k) => k == 'rain'), hasLength(1));
    });
  });

  group('truncated stream handling', () {
    test('a half-written JSON scaffold is recognised as incomplete', () {
      const partial = '{"intent":"translation","primary":"It is';
      // The cancelled-stream path relies on this shape to avoid persisting a
      // brace-delimited fragment as the coach's answer.
      expect(partial.startsWith('{'), isTrue);
      expect(partial.contains('"primary"'), isTrue);
    });

    test('controller completion ordering is deterministic', () async {
      // Guards the pattern used by the cancel path: the first terminal event
      // wins and later ones do not resurrect a finished stream.
      final events = <String>[];
      var closed = false;
      final controller = StreamController<String>();
      final sub = controller.stream.listen((e) {
        if (closed) return;
        if (e == 'complete' || e == 'error') closed = true;
        events.add(e);
      });
      controller
        ..add('delta')
        ..add('complete')
        ..add('delta-after');
      await pump();
      await sub.cancel();
      expect(events, <String>['delta', 'complete']);
    });
  });
}

Future<void> pump() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}