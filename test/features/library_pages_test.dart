import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/application/library/home_feed.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/domain/models/catalog.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/ports/catalog_repository.dart';
import 'package:zero/features/home/home_page.dart';
import 'package:zero/features/library/continue_watching_card.dart';
import 'package:zero/features/library/media_poster.dart';
import 'package:zero/features/schedule/schedule_page.dart';
import 'package:zero/features/search/search_page.dart';

Media media(int id, String title) => Media(
  id: id,
  title: MediaTitle(userPreferred: title),
  format: MediaFormat.tv,
  status: MediaStatus.finished,
  episodes: 12,
  averageScore: 84,
  description: 'A quiet test synopsis.',
);

class _FakeCatalog implements CatalogRepository {
  _FakeCatalog({this.failSchedule = false});

  bool failSchedule;
  final List<MediaBrowseQuery> queries = [];

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) async {
    queries.add(query);
    if (query.statuses.contains(MediaStatus.releasing)) {
      if (failSchedule) throw StateError('schedule unavailable');
      return MediaPage(
        items: [
          Media(
            id: 20,
            title: const MediaTitle(userPreferred: 'Night Broadcast'),
            format: MediaFormat.tv,
            status: MediaStatus.releasing,
            synonyms: const ['Midnight Show'],
            nextAiringEpisode: AiringEpisode(
              episode: 7,
              airingAt: DateTime.now().add(const Duration(hours: 8)),
            ),
          ),
          Media(
            id: 21,
            title: const MediaTitle(userPreferred: 'Weekend Broadcast'),
            format: MediaFormat.tv,
            status: MediaStatus.releasing,
            nextAiringEpisode: AiringEpisode(
              episode: 2,
              airingAt: DateTime.now().add(const Duration(days: 2)),
            ),
          ),
        ],
        hasNextPage: false,
      );
    }
    if (query.search?.trim() == 'Monster') {
      return MediaPage(items: [media(3, 'Monster')], hasNextPage: false);
    }
    if (query.sort == MediaSort.popularity && query.year != null) {
      return MediaPage(items: [media(4, 'New Show')], hasNextPage: false);
    }
    if (query.sort == MediaSort.popularity) {
      return MediaPage(items: [media(2, 'Popular Show')], hasNextPage: false);
    }
    return MediaPage(items: [media(1, 'Seasonal Show')], hasNextPage: false);
  }

  @override
  Future<Media?> mediaById(int id) async => null;

  @override
  Future<List<Media>> similar(int mediaId) async => const [];
}

class _DeferredSearchCatalog extends _FakeCatalog {
  final monster = Completer<MediaPage>();

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) {
    if (query.search?.trim() == 'Monster') return monster.future;
    return super.browse(query);
  }
}

Widget _app(Widget child, _FakeCatalog catalog) => ProviderScope(
  overrides: [catalogRepositoryProvider.overrideWithValue(catalog)],
  child: MaterialApp(
    theme: buildZeroTheme(),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('Home renders the real hero and catalogue rails', (tester) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(_app(const HomePage(), catalog));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Seasonal Show'), findsWidgets);
    expect(find.text('84%'), findsWidgets);
    expect(find.text('For you'), findsOneWidget);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -800));
    await tester.pump();
    expect(find.text('Trending this season'), findsOneWidget);
    expect(find.text('Browse by genre'), findsNothing);
    expect(catalog.queries, hasLength(3));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1200));
    await tester.pump();
    expect(find.text('Popular Show'), findsOneWidget);
    expect(find.text('All-time popular'), findsOneWidget);
  });

  testWidgets('Continue watching follows For You and shows resume progress', (
    tester,
  ) async {
    // Tall viewport so both personalized rails build inside the sliver list.
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final catalog = _FakeCatalog();
    final show = media(
      9,
      'Half Watched',
    ).withListEntry(const ListEntry(status: ListStatus.current, progress: 1));
    final personalized = PersonalizedHomeFeed(
      continueWatching: [
        ContinueWatchingItem(media: show, episode: 2, resumeProgress: 0.35),
      ],
      recommendations: [media(30, 'Suggested Show')],
      favoriteGenres: const ['Action'],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(catalog),
          personalizedHomeFeedProvider.overrideWith((ref) => personalized),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const Scaffold(body: HomePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    // The resume rail sits below For You so a sparse row never leads the page.
    final forYouY = tester.getTopLeft(find.text('For you · Action')).dy;
    final continueY = tester.getTopLeft(find.text('Continue watching')).dy;
    expect(continueY, greaterThan(forYouY));

    expect(find.text('Half Watched'), findsOneWidget);
    expect(find.text('EP 2'), findsOneWidget);
    expect(find.text('Ep 2 of 12'), findsOneWidget);
    expect(find.text('35% watched'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.descendant(
        of: find.byType(ContinueWatchingCard),
        matching: find.byType(LinearProgressIndicator),
      ),
    );
    expect(bar.value, closeTo(0.35, 0.001));
  });

  testWidgets('a cold-start profile keeps the normal For You rail', (
    tester,
  ) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          catalogRepositoryProvider.overrideWithValue(catalog),
          personalizedHomeFeedProvider.overrideWith(
            (ref) => PersonalizedHomeFeed(
              recommendations: [media(31, 'Starter Show')],
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const Scaffold(body: HomePage()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('For you'), findsOneWidget);
    expect(find.text('Start here'), findsNothing);
    expect(find.text('Starter Show'), findsOneWidget);
  });

  testWidgets('Search loads an initial page and submits a title query', (
    tester,
  ) async {
    final catalog = _FakeCatalog();
    await tester.pumpWidget(_app(const SearchPage(), catalog));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Seasonal Show'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Monster');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(
      find.descendant(
        of: find.byType(MediaPoster),
        matching: find.text('Monster'),
      ),
      findsOneWidget,
    );
    expect(catalog.queries.last.search, 'Monster');
    expect(catalog.queries.last.page, 1);
  });

  testWidgets('Search preserves current results while a new query loads', (
    tester,
  ) async {
    final catalog = _DeferredSearchCatalog();
    await tester.pumpWidget(_app(const SearchPage(), catalog));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    await tester.enterText(find.byType(TextField), 'Monster');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(find.text('Seasonal Show'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    catalog.monster.complete(
      MediaPage(items: [media(3, 'Monster')], hasNextPage: false),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Seasonal Show'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(MediaPoster),
        matching: find.text('Monster'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('Search applies populated discovery filters to the catalogue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final catalog = _FakeCatalog();
    await tester.pumpWidget(_app(const SearchPage(), catalog));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.byKey(const ValueKey('toggle-search-filters')));
    await tester.pumpAndSettle();
    final queriesBeforeToggles = catalog.queries.length;
    await tester.tap(find.widgetWithText(FilterChip, 'TV'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Action'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Airing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 20));

    // The debounce folds three quick chip taps into one catalogue request.
    expect(catalog.queries.length, queriesBeforeToggles + 1);
    final query = catalog.queries.last;
    expect(query.page, 1);
    expect(query.formats, contains(MediaFormat.tv));
    expect(query.genres, contains('Action'));
    expect(query.statuses, contains(MediaStatus.releasing));
    expect(find.text('3'), findsWidgets, reason: 'active-filter badge');

    await tester.tap(find.text('Reset filters'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 20));
    expect(catalog.queries.last.formats, isEmpty);
    expect(catalog.queries.last.genres, isEmpty);
    expect(catalog.queries.last.statuses, isEmpty);
  });

  testWidgets('Schedule shows ordered airings and filters synonyms', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final catalog = _FakeCatalog();
    await tester.pumpWidget(_app(const SchedulePage(), catalog));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Episode 7 in'), findsOneWidget);
    expect(find.text('Episode 2 in'), findsOneWidget);
    expect(find.text('Night Broadcast'), findsOneWidget);
    expect(find.text('Weekend Broadcast'), findsOneWidget);
    expect(catalog.queries.last.statuses, [MediaStatus.releasing]);

    await tester.enterText(
      find.byKey(const ValueKey('schedule-filter')),
      'Midnight',
    );
    await tester.pump();

    expect(find.text('Night Broadcast'), findsOneWidget);
    expect(find.text('Weekend Broadcast'), findsNothing);
  });

  testWidgets('Schedule exposes failure and retry states', (tester) async {
    final catalog = _FakeCatalog(failSchedule: true);
    await tester.pumpWidget(_app(const SchedulePage(), catalog));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Schedule is unavailable'), findsOneWidget);

    catalog.failSchedule = false;
    await tester.tap(find.text('Try again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Night Broadcast'), findsOneWidget);
    expect(catalog.queries.length, 2);
  });
}
