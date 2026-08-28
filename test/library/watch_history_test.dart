import 'package:flutter_test/flutter_test.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/media_codec.dart';
import 'package:zero/infrastructure/database/database.dart';
import 'package:zero/infrastructure/database/watch_history_repository_impl.dart';

const _show = Media(
  id: 42,
  idMal: 4242,
  title: MediaTitle(userPreferred: 'Penal Hero Unit', romaji: 'Yuusha Kei'),
  format: MediaFormat.tv,
  status: MediaStatus.releasing,
  season: MediaSeason.winter,
  seasonYear: 2026,
  episodes: 12,
  duration: 25,
  coverImage: 'https://img.example/cover.png',
  genres: ['Action', 'Fantasy'],
  averageScore: 81,
  synonyms: ['Sentence'],
);

void main() {
  group('media snapshot codec', () {
    test('round-trips every persisted field', () {
      final media = Media(
        id: 7,
        title: MediaTitle(english: 'A Show', native: 'ショー'),
        format: MediaFormat.movie,
        status: MediaStatus.finished,
        season: MediaSeason.fall,
        seasonYear: 2020,
        episodes: 1,
        duration: 110,
        coverImage: 'c',
        bannerImage: 'b',
        coverColor: '#e4a15d',
        description: 'desc',
        genres: ['Drama'],
        averageScore: 74,
        isAdult: true,
        nextAiringEpisode: AiringEpisode(
          episode: 2,
          airingAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
        ),
        synonyms: const ['alias'],
      );
      final restored = mediaFromJson(mediaToJson(media))!;
      expect(restored.id, 7);
      expect(restored.title.english, 'A Show');
      expect(restored.title.native, 'ショー');
      expect(restored.format, MediaFormat.movie);
      expect(restored.status, MediaStatus.finished);
      expect(restored.season, MediaSeason.fall);
      expect(restored.seasonYear, 2020);
      expect(restored.episodes, 1);
      expect(restored.duration, 110);
      expect(restored.coverImage, 'c');
      expect(restored.bannerImage, 'b');
      expect(restored.coverColor, '#e4a15d');
      expect(restored.description, 'desc');
      expect(restored.genres, ['Drama']);
      expect(restored.averageScore, 74);
      expect(restored.isAdult, isTrue);
      expect(restored.nextAiringEpisode!.episode, 2);
      expect(
        restored.nextAiringEpisode!.airingAt.millisecondsSinceEpoch,
        1700000000000,
      );
      expect(restored.synonyms, ['alias']);
      expect(restored.listEntry, isNull);
    });

    test('tolerates malformed input', () {
      expect(mediaFromJson(null), isNull);
      expect(mediaFromJson('junk'), isNull);
      expect(mediaFromJson({'title': 'x'}), isNull);
      final minimal = mediaFromJson({'id': 3})!;
      expect(minimal.id, 3);
      expect(minimal.genres, isEmpty);
    });
  });

  group('SqliteWatchHistoryRepository', () {
    late AppDatabase database;
    late SqliteWatchHistoryRepository history;
    var now = DateTime(2026, 8, 27, 20);

    setUp(() {
      database = AppDatabase.inMemory();
      history = SqliteWatchHistoryRepository(database, clock: () => now);
    });

    tearDown(() {
      history.dispose();
      database.close();
    });

    test('records and reads back one episode', () async {
      await history.record(
        media: _show,
        episode: 3,
        position: const Duration(minutes: 8),
        duration: const Duration(minutes: 24),
      );
      final progress = (await history.progressFor(42, 3))!;
      expect(progress.position, const Duration(minutes: 8));
      expect(progress.duration, const Duration(minutes: 24));
      expect(progress.completed, isFalse);
      expect(progress.fraction, closeTo(8 / 24, 0.001));
      expect(await history.watchedThrough(42), 0);
    });

    test('completion latches and survives a partial rewatch', () async {
      await history.record(
        media: _show,
        episode: 3,
        position: const Duration(minutes: 22),
        duration: const Duration(minutes: 24),
        completed: true,
      );
      await history.record(
        media: _show,
        episode: 3,
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 24),
      );
      final progress = (await history.progressFor(42, 3))!;
      expect(progress.completed, isTrue);
      expect(progress.position, const Duration(minutes: 2));
      expect(await history.watchedThrough(42), 3);
    });

    test('recent orders by recency and carries resume state', () async {
      await history.record(
        media: _show,
        episode: 1,
        position: const Duration(minutes: 24),
        duration: const Duration(minutes: 24),
        completed: true,
      );
      now = now.add(const Duration(minutes: 5));
      await history.record(
        media: _show,
        episode: 2,
        position: const Duration(minutes: 9),
        duration: const Duration(minutes: 24),
      );
      now = now.add(const Duration(minutes: 5));
      const other = Media(id: 99, title: MediaTitle(userPreferred: 'Other'));
      await history.record(
        media: other,
        episode: 5,
        position: const Duration(minutes: 12),
        duration: const Duration(minutes: 24),
      );

      final entries = await history.recent();
      expect(entries.length, 2);
      expect(entries.first.media.id, 99);
      final show = entries.last;
      expect(show.media.title.display, 'Penal Hero Unit');
      expect(show.watchedThrough, 1);
      expect(show.resume!.episode, 2);
      expect(show.resume!.position, const Duration(minutes: 9));
      expect(show.nextEpisode, 2);
    });

    test('progressForMedia lists every recorded episode in order', () async {
      await history.record(
        media: _show,
        episode: 2,
        position: const Duration(minutes: 9),
        duration: const Duration(minutes: 24),
      );
      await history.record(
        media: _show,
        episode: 1,
        position: const Duration(minutes: 24),
        duration: const Duration(minutes: 24),
        completed: true,
      );
      await history.record(
        media: const Media(id: 99, title: MediaTitle(userPreferred: 'Other')),
        episode: 1,
        position: const Duration(minutes: 4),
        duration: const Duration(minutes: 24),
      );

      final rows = await history.progressForMedia(42);
      expect(rows.map((row) => row.episode), [1, 2]);
      expect(rows.first.completed, isTrue);
      expect(rows.last.fraction, closeTo(9 / 24, 0.001));
    });

    test('a barely-opened episode is not a resume candidate', () async {
      await history.record(
        media: _show,
        episode: 4,
        position: const Duration(seconds: 10),
        duration: const Duration(minutes: 24),
      );
      final entries = await history.recent();
      expect(entries.single.resume, isNull);
      expect(entries.single.watchedThrough, 0);
    });

    test('forget removes the show and notifies listeners', () async {
      var notified = 0;
      final subscription = history.changes.listen((_) => notified++);
      addTearDown(subscription.cancel);
      await history.record(
        media: _show,
        episode: 1,
        position: const Duration(minutes: 5),
        duration: const Duration(minutes: 24),
      );
      await history.forget(42);
      await Future<void>.delayed(Duration.zero);
      expect(await history.recent(), isEmpty);
      expect(await history.progressFor(42, 1), isNull);
      expect(notified, 2);
    });
  });
}
