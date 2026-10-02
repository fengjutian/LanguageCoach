import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/asr_engine.dart';
import 'package:language_coach/core/audio/asr_model_profile.dart';
import 'package:language_coach/core/native/native_ai_bridge.dart';

void main() {
  group('AsrModelProfile + bestFit', () {
    test('knownAsrProfiles returns curated entries', () {
      final profiles = knownAsrProfiles();
      expect(profiles, isNotEmpty);
      expect(
        profiles.any((p) => p.languageCode == 'zh-CN'),
        isTrue,
      );
      expect(
        profiles.any((p) => p.languageCode == 'en-US'),
        isTrue,
      );
    });

    test('bestFit picks the highest-accuracy match for the exact language', () {
      final profiles = knownAsrProfiles();
      final match = bestFit('zh-CN', profiles)!;
      expect(match.languageCode, 'zh-CN');
    });

    test('bestFit falls back to highest-accuracy profile on language miss', () {
      final profiles = knownAsrProfiles();
      // Pretend only `en-US` is installed for some reason — bestFit should
      // still hand back something rather than null.
      final installed = profiles.where((p) => p.languageCode == 'en-US');
      final match = bestFit('zh-CN', installed);
      expect(match, isNotNull);
      expect(match!.languageCode, 'en-US');
    });

    test('bestFit returns null when nothing is installed', () {
      expect(bestFit('zh-CN', const <AsrModelProfile>[]), isNull);
    });
  });

  group('AsrResult event decoder', () {
    test('decodes ASR_PARTIAL into AsrPartial', () {
      final result = <String, Object?>{
        'type': 'ASR_PARTIAL',
        'payload': {'text': 'partial...'},
      }.toAsrResult();
      expect(result, isA<AsrPartial>());
      expect((result as AsrPartial).text, 'partial...');
    });

    test('decodes ASR_FINAL into AsrFinal with language', () {
      final result = <String, Object?>{
        'type': 'ASR_FINAL',
        'payload': {'text': 'done.', 'language': 'en-US'},
      }.toAsrResult();
      expect(result, isA<AsrFinal>());
      expect((result as AsrFinal).languageCode, 'en-US');
    });

    test('decodes ASR_ERROR with permission code into AsrFailure', () {
      final result = <String, Object?>{
        'type': 'ASR_ERROR',
        'payload': {'code': 4, 'message': 'denied'},
      }.toAsrResult();
      expect(result, isA<AsrFailure>());
      expect((result as AsrFailure).kind, AsrErrorKind.permissionDenied);
    });

    test('returns null for unknown payload shapes', () {
      expect(<String, Object?>{'foo': 'bar'}.toAsrResult(), isNull);
    });
  });
}
