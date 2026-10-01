import 'package:flutter/foundation.dart';

enum AiProvider { auto, miniMax, deepSeek, localQwen }

enum CoachLanguage {
  english('en', 'English', '🇺🇸'),
  japanese('ja', '日本語', '🇯🇵'),
  french('fr', 'Français', '🇫🇷'),
  korean('ko', '한국어', '🇰🇷'),
  spanish('es', 'Español', '🇪🇸'),
  german('de', 'Deutsch', '🇩🇪'),
  italian('it', 'Italiano', '🇮🇹'),
  chinese('zh-CN', '中文', '🇨🇳'),
  russian('ru', 'Русский', '🇷🇺'),
  portuguese('pt', 'Português', '🇵🇹');

  const CoachLanguage(this.code, this.label, this.flag);
  final String code;
  final String label;
  final String flag;
}

class AppSettings extends ChangeNotifier {
  CoachLanguage _preferredLanguage = CoachLanguage.english;
  AiProvider _provider = AiProvider.auto;
  double _speechSpeed = 1;
  bool _autoPlay = false;
  bool _saveHistory = true;

  CoachLanguage get preferredLanguage => _preferredLanguage;
  AiProvider get provider => _provider;
  double get speechSpeed => _speechSpeed;
  bool get autoPlay => _autoPlay;
  bool get saveHistory => _saveHistory;

  void setPreferredLanguage(CoachLanguage value) {
    _preferredLanguage = value;
    notifyListeners();
  }

  void setProvider(AiProvider value) {
    _provider = value;
    notifyListeners();
  }

  void setSpeechSpeed(double value) {
    _speechSpeed = value;
    notifyListeners();
  }

  void setAutoPlay(bool value) {
    _autoPlay = value;
    notifyListeners();
  }

  void setSaveHistory(bool value) {
    _saveHistory = value;
    notifyListeners();
  }
}
