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
  final List<MediaBrowseQuery> queries = [];

  @override
  Future<MediaPage> browse(MediaBrowseQuery query) async {
    queries.add(query);
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
}
