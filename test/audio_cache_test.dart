import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:language_coach/core/audio/audio_cache.dart';
import 'package:language_coach/core/audio/audio_player.dart';
import 'package:language_coach/core/database/app_database.dart';
import 'package:language_coach/core/database/app_database_provider.dart';
import 'package:language_coach/core/models/app_settings.dart';
import 'package:language_coach/features/chat/application/tts_controller.dart';
import 'package:language_coach/features/settings/application/settings_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeSeededSettingsController extends SettingsController {
  @override
  AppSettings build() => AppSettings.defaults;
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late AppDatabase db;
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('audio_cache_test_');
    db = await AppDatabase.open(overridePath: '${tmp.path}/test.db');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('record + lookup round-trips', () async {
    final cache = AudioCacheRepository(db, rootDirectory: tmp);
    final path = await cache.pathFor(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
    );
    File(path).writeAsBytesSync(List<int>.filled(16, 0));
    await cache.record(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
      audioPath: path,
      bytes: 16,
      format: 'wav',
      duration: const Duration(seconds: 1),
      language: 'en',
      voiceId: 'default',
      speed: 1.0,
      modelVersion: 'fake-tts',
    );
    final lookup = await cache.lookup(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
    );
    expect(lookup, isNotNull);
    expect(lookup!.audioPath, path);
    expect(lookup.duration, const Duration(seconds: 1));
  });

  test('cleanupOrphans removes files not in SQLite', () async {
    final cache = AudioCacheRepository(db, rootDirectory: tmp);
    final orphanPath = await cache.pathFor(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 'orphan',
    );
    File(orphanPath).writeAsBytesSync(List<int>.filled(8, 0));
    final removed = await cache.cleanupOrphans();
    expect(removed, 1);
    expect(File(orphanPath).existsSync(), isFalse);
  });

  test('cleanupOrphans keeps files the DB knows about', () async {
    final cache = AudioCacheRepository(db, rootDirectory: tmp);
    final path = await cache.pathFor(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
    );
    File(path).writeAsBytesSync(List<int>.filled(8, 0));
    await cache.record(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
      audioPath: path,
      bytes: 8,
      format: 'wav',
      language: 'en',
      voiceId: 'default',
      speed: 1.0,
      modelVersion: 'fake-tts',
    );
    final removed = await cache.cleanupOrphans();
    expect(removed, 0);
    expect(File(path).existsSync(), isTrue);
  });

  test('cache hit marks sentence as cached in TtsController', () async {
    final cache = AudioCacheRepository(db, rootDirectory: tmp);
    final path = await cache.pathFor(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
    );
    File(path).writeAsBytesSync(List<int>.filled(8, 0));
    await cache.record(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
      audioPath: path,
      bytes: 8,
      format: 'wav',
      duration: const Duration(milliseconds: 500),
      language: 'en',
      voiceId: 'default',
      speed: 1.0,
      modelVersion: 'fake-tts',
    );

    final container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      audioCacheRepositoryProvider.overrideWithValue(cache),
      audioPlayerServiceProvider.overrideWithValue(InMemoryAudioPlayer()),
      settingsControllerProvider.overrideWith(
        () => _FakeSeededSettingsController(),
      ),
    ]);
    addTearDown(container.dispose);

    final tts = container.read(ttsControllerProvider.notifier);
    await tts.playSingleSentence(
      conversationId: 'c1',
      messageId: 'm1',
      sentenceId: 's0',
      text: 'hello',
    );
    final state = container.read(ttsControllerProvider);
    expect(state.sentenceStates['s0'], SentencePlaybackState.cached);
  });
}
