import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/application/library/providers.dart';
import 'package:zeroshiru/domain/models/catalog.dart';
import 'package:zeroshiru/domain/models/media.dart';
import 'package:zeroshiru/domain/ports/catalog_repository.dart';
import 'package:zeroshiru/features/home/home_page.dart';
import 'package:zeroshiru/features/library/media_poster.dart';
import 'package:zeroshiru/features/schedule/schedule_page.dart';
import 'package:zeroshiru/features/search/search_page.dart';

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
    if (query.sort == MediaSort.popularity) {
      return MediaPage(items: [media(2, 'Popular Show')], hasNextPage: false);
    }
    return MediaPage(items: [media(1, 'Seasonal Show')], hasNextPage: false);
  }

  @override
  Future<Media?> mediaById(int id) async => null;
}

Widget _app(Widget child, _FakeCatalog catalog) => ProviderScope(
  overrides: [catalogRepositoryProvider.overrideWithValue(catalog)],
  child: MaterialApp(
    theme: buildShiruTheme(),
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
    expect(find.text('Trending this season'), findsOneWidget);
    expect(catalog.queries, hasLength(2));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pump();
    expect(find.text('Popular Show'), findsOneWidget);
    expect(find.text('All-time popular'), findsOneWidget);
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
    await tester.tap(find.widgetWithText(FilterChip, 'TV'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Action'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Airing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    final query = catalog.queries.last;
    expect(query.page, 1);
    expect(query.formats, contains(MediaFormat.tv));
    expect(query.genres, contains('Action'));
    expect(query.statuses, contains(MediaStatus.releasing));
    expect(find.text('3'), findsWidgets, reason: 'active-filter badge');

    await tester.tap(find.text('Reset filters'));
    await tester.pump();
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
