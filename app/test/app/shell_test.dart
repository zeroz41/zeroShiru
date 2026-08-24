import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zeroshiru/app/shell.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/app/theme/tokens.dart';

GoRouter _router(String initial) {
  return GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          for (final d in AppShell.destinations)
            GoRoute(
              path: d.path,
              pageBuilder: (context, state) => NoTransitionPage(
                child: Center(child: Text('page:${d.label}')),
              ),
            ),
        ],
      ),
    ],
  );
}

Widget _app(GoRouter router) {
  return MaterialApp.router(theme: buildShiruTheme(), routerConfig: router);
}

/// Finds the nav item Semantics for [label] and reports its selected flag.
bool _navSelected(WidgetTester tester, String label) {
  final semantics = tester
      .widgetList<Semantics>(find.byType(Semantics))
      .where(
        (s) => s.properties.label == label && s.properties.selected != null,
      );
  expect(
    semantics,
    hasLength(1),
    reason: 'expected one nav item labelled $label',
  );
  return semantics.first.properties.selected!;
}

void main() {
  testWidgets('desktop shell shows the labelled left rail with all nav items', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_router('/home')));
    await tester.pumpAndSettle();

    for (final d in AppShell.destinations) {
      expect(find.text(d.label), findsOneWidget);
    }
    expect(find.text('page:Home'), findsOneWidget);

    // The rail is exactly the token width.
    final railBox = tester.renderObject<RenderBox>(
      find
          .ancestor(of: find.text('Home'), matching: find.byType(Container))
          .last,
    );
    expect(railBox.size.width, ShiruTokens.sidebarWidth);
  });

  testWidgets('active nav item follows the location', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final router = _router('/home');
    await tester.pumpWidget(_app(router));
    await tester.pumpAndSettle();

    expect(_navSelected(tester, 'Home'), isTrue);
    expect(_navSelected(tester, 'Search'), isFalse);

    router.go('/search');
    await tester.pumpAndSettle();

    expect(find.text('page:Search'), findsOneWidget);
    expect(_navSelected(tester, 'Home'), isFalse);
    expect(_navSelected(tester, 'Search'), isTrue);
  });

  testWidgets('tapping a nav item navigates', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_router('/home')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Downloads'));
    await tester.pumpAndSettle();

    expect(find.text('page:Downloads'), findsOneWidget);
    expect(_navSelected(tester, 'Downloads'), isTrue);
  });

  testWidgets('below the 769px breakpoint the shell uses a bottom bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_router('/home')));
    await tester.pumpAndSettle();

    for (final d in AppShell.destinations) {
      expect(find.text(d.label), findsOneWidget);
    }

    // Nav sits below the page content (bottom bar, not a left rail).
    final navCenter = tester.getCenter(find.text('Home'));
    final pageCenter = tester.getCenter(find.text('page:Home'));
    expect(navCenter.dy, greaterThan(pageCenter.dy));
    expect(navCenter.dy, greaterThan(800 - ShiruTokens.sidebarWidth - 1));
  });

  testWidgets('mobile More menu exposes useful shell utilities', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_router('/home')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();

    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('About & shortcuts'), findsOneWidget);

    await tester.tap(find.text('Updates'));
    await tester.pumpAndSettle();
    expect(find.text('You’re all caught up'), findsOneWidget);
  });
}
