import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/language/target_language_resolver.dart';
import 'package:language_coach/core/models/app_settings.dart';

void main() {
  const preferred = CoachLanguage.english;
  final resolver = TargetLanguageResolver();

  test('explicit language wins over preference', () {
    expect(resolver.resolve('日语怎么说？', preferred), CoachLanguage.japanese);
    expect(resolver.resolve('法语呢？', preferred), CoachLanguage.french);
  });

  test('preference is used when language is not explicit', () {
    expect(
      resolver.resolve('今天下雨怎么说？', CoachLanguage.german),
      CoachLanguage.german,
    );
  });
}
