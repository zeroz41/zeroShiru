import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/playback/preferences.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/models/torrent.dart';
import 'package:zero/infrastructure/database/database.dart';
import 'package:zero/infrastructure/database/settings_repository_impl.dart';

void main() {
  late AppDatabase database;
  late SqliteSettingsRepository settings;

  setUp(() {
    database = AppDatabase.inMemory();
    settings = SqliteSettingsRepository(database);
  });

  tearDown(() {
    settings.dispose();
    database.close();
  });

  test(
    'subtitle timing roundtrips per release without leaking across releases',
    () async {
      final store = PlaybackTuningStore(settings);
      const tuning = PlaybackTuning(
        primarySubtitleDelay: Duration(milliseconds: 350),
        secondarySubtitleDelay: Duration(milliseconds: -125),
      );

      await store.write('release-a', tuning);

      expect(
        store.read('release-a').primarySubtitleDelay,
        tuning.primarySubtitleDelay,
      );
      expect(
        store.read('release-a').secondarySubtitleDelay,
        tuning.secondarySubtitleDelay,
      );
      expect(store.read('release-b').primarySubtitleDelay, Duration.zero);
    },
  );

  test('tuning copyWith changes one delay without resetting the other', () {
    const tuning = PlaybackTuning(
      primarySubtitleDelay: Duration(milliseconds: 350),
      secondarySubtitleDelay: Duration(milliseconds: -125),
    );

    final changed = tuning.copyWith(
      secondarySubtitleDelay: const Duration(milliseconds: 75),
    );

    expect(changed.primarySubtitleDelay, tuning.primarySubtitleDelay);
    expect(changed.secondarySubtitleDelay, const Duration(milliseconds: 75));
  });

  test('playback preferences share one mapping for every subtitle mode', () {
    const settings = Settings(audioLanguage: 'eng', subtitleLanguage: 'es');

    final standard = playbackPreferencesFor(settings);
    final learning = playbackPreferencesFor(settings, subtitleMode: 'learning');
    final off = playbackPreferencesFor(settings, subtitleMode: 'off');

    expect(standard.audioLanguage, 'eng');
    expect(standard.subtitleLanguage, 'es');
    expect(standard.subtitlesEnabled, isTrue);
    expect(learning.subtitleLanguage, 'jpn');
    expect(learning.subtitlesEnabled, isTrue);
    expect(off.subtitleLanguage, 'es');
    expect(off.subtitlesEnabled, isFalse);
  });

  test('tuning identity uses stable non-secret media facts only', () {
    expect(
      playbackTuningIdentity(
        const PlayerFile(
          name: 'Show 07.mkv',
          url: 'https://cdn.example/video?secret=signed',
          infoHash: 'ABCDEF',
          fileHash: 'file-hash',
        ),
      ),
      'abcdef',
    );
    expect(
      playbackTuningIdentity(
        const PlayerFile(
          name: 'Show 07.mkv',
          url: 'https://cdn.example/video?secret=signed',
        ),
      ),
      isNull,
    );
  });
}
