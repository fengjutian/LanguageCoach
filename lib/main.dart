import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'app/language_coach_app.dart';
import 'core/audio/audio_cache.dart';
import 'core/audio/just_audio_player.dart';
import 'core/database/app_database.dart';
import 'core/database/app_database_provider.dart';
import 'core/models/app_settings.dart';
import 'core/repositories/sqlite_settings_repository.dart';
import 'features/chat/application/tts_controller.dart';
import 'features/practice/application/practice_controller.dart';
import 'features/practice/data/practice_repository.dart';
import 'features/settings/application/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Open SQLite + load persisted settings before the first frame so the
  // chat page can resume the right conversation immediately.
  final db = await AppDatabase.open();
  final raw = await SqliteSettingsRepository(db).loadRaw();
  final initial = AppSettings.fromJson(raw);
  final docsDir = await getApplicationDocumentsDirectory();
  final audioCacheDir = Directory('${docsDir.path}/audio');
  if (!audioCacheDir.existsSync()) audioCacheDir.createSync(recursive: true);

  // Best-effort orphan cleanup — does not block app start.
  // ignore: discarded_futures
  AudioCacheRepository(db, rootDirectory: docsDir).cleanupOrphans();

  runApp(ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      settingsControllerProvider.overrideWith(
        () => _SeededSettingsController(initial),
      ),
      audioPlayerServiceProvider.overrideWithValue(JustAudioPlayer()),
      ttsOutputDirectoryProvider.overrideWithValue(audioCacheDir),
      audioCacheRepositoryProvider.overrideWithValue(
        AudioCacheRepository(db, rootDirectory: docsDir),
      ),
      practiceRepositoryProvider.overrideWithValue(SqlitePracticeRepository(db)),
    ],
    child: const LanguageCoachApp(),
  ));
}

class _SeededSettingsController extends SettingsController {
  _SeededSettingsController(this._initial);
  final AppSettings _initial;

  @override
  AppSettings build() {
    return _initial;
  }
}
