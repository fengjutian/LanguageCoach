import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/language_coach_app.dart';
import 'core/database/app_database.dart';
import 'core/database/app_database_provider.dart';
import 'core/models/app_settings.dart';
import 'core/repositories/sqlite_settings_repository.dart';
import 'features/settings/application/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Open SQLite + load persisted settings before the first frame so the
  // chat page can resume the right conversation immediately.
  final db = await AppDatabase.open();
  final raw = await SqliteSettingsRepository(db).loadRaw();
  final initial = AppSettings.fromJson(raw);

  runApp(ProviderScope(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      settingsControllerProvider.overrideWith(
        () => _SeededSettingsController(initial),
      ),
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
