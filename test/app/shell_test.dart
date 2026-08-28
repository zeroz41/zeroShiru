import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero/app/shell.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/app/theme/tokens.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/tracking_account.dart';
import 'package:zero/domain/ports/ports.dart';

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
  return MaterialApp.router(theme: buildZeroTheme(), routerConfig: router);
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
  testWidgets('desktop shell expands from an efficient icon rail', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(_router('/home')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('desktop-menu-toggle')), findsOneWidget);
    expect(find.text('Home'), findsNothing);
    expect(find.text('page:Home'), findsOneWidget);

    expect(
      tester
          .getSize(find.byKey(const ValueKey('desktop-navigation-rail')))
          .width,
      ZeroTokens.sidebarWidth,
    );
    final pageCenter = tester.getCenter(find.text('page:Home'));

    await tester.tap(find.byKey(const ValueKey('desktop-menu-toggle')));
    await tester.pump(const Duration(milliseconds: 80));

    // Expanding the overlay rail must not repeatedly re-layout the page.
    expect(tester.getCenter(find.text('page:Home')), pageCenter);
    await tester.pumpAndSettle();

    for (final d in AppShell.destinations) {
      expect(find.text(d.label), findsOneWidget);
    }
    expect(find.text('Zero'), findsOneWidget);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('desktop-navigation-rail')))
          .width,
      ZeroTokens.sidebarExpandedWidth,
    );
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

    await tester.tap(find.byKey(const ValueKey('desktop-menu-toggle')));
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

    for (final d in AppShell.destinations.take(4)) {
      expect(find.text(d.label), findsOneWidget);
    }
    expect(find.text('Settings'), findsNothing);
    expect(find.text('More'), findsOneWidget);

    // Nav sits below the page content (bottom bar, not a left rail).
    final navCenter = tester.getCenter(find.text('Home'));
    final pageCenter = tester.getCenter(find.text('page:Home'));
    expect(navCenter.dy, greaterThan(pageCenter.dy));
    expect(navCenter.dy, greaterThan(800 - ZeroTokens.sidebarWidth - 1));
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
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('About & shortcuts'), findsOneWidget);

    await tester.tap(find.text('Updates'));
    await tester.pumpAndSettle();
    expect(find.text('You’re all caught up'), findsOneWidget);
  });

  testWidgets('profile account actions fit in the narrow mobile menu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tracking = _ConnectableTracking(
      initialAccounts: const [
        TrackingAccount(
          service: TrackingAccountService.aniList,
          displayName: 'A deliberately long account name',
          health: TrackingAccountHealth.expired,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [trackingRepositoryProvider.overrideWithValue(tracking)],
        child: _app(_router('/home')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Profile'));
    await tester.pumpAndSettle();

    expect(find.text('Reconnect required'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('account-actions-aniList')));
    await tester.pumpAndSettle();

    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the profile panel connects AniList from a pasted redirect', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tracking = _ConnectableTracking();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [trackingRepositoryProvider.overrideWithValue(tracking)],
        child: _app(_router('/home')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('connect-anilist')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('anilist-redirect')),
      'shiru://alauth#access_token=pasted-token&token_type=Bearer',
    );
    await tester.tap(find.byKey(const ValueKey('anilist-connect-submit')));
    await tester.pumpAndSettle();

    expect(tracking.pasted, [
      'shiru://alauth#access_token=pasted-token&token_type=Bearer',
    ]);
    expect(find.byKey(const ValueKey('anilist-redirect')), findsNothing);
    expect(find.text('AniList connected as Frieren'), findsOneWidget);
  });

  testWidgets('a rejected paste keeps the dialog open with the reason', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tracking = _ConnectableTracking(reject: true);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [trackingRepositoryProvider.overrideWithValue(tracking)],
        child: _app(_router('/home')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.account_circle_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connect-anilist')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('anilist-redirect')),
      'not a token',
    );
    await tester.tap(find.byKey(const ValueKey('anilist-connect-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('anilist-redirect')), findsOneWidget);
    expect(
      find.textContaining('does not contain an AniList token'),
      findsOneWidget,
    );
  });
}

class _ConnectableTracking implements TrackingRepository {
  _ConnectableTracking({this.reject = false, this.initialAccounts = const []});

  final bool reject;
  final List<TrackingAccount> initialAccounts;
  final pasted = <String>[];

  @override
  Future<List<TrackingAccount>> accounts() async => initialAccounts;

  @override
  Future<TrackingAccount> connectAniList(String text) async {
    if (reject) {
      throw ArgumentError('That text does not contain an AniList token.');
    }
    pasted.add(text);
    return const TrackingAccount(
      service: TrackingAccountService.aniList,
      displayName: 'Frieren',
      health: TrackingAccountHealth.connected,
    );
  }

  @override
  Future<void> disconnect(TrackingAccountService service) async {}

  @override
  Future<Media?> mediaById(int id) async => null;

  @override
  Future<List<Media>> search(String query, {int page = 1}) async => const [];

  @override
  Future<List<Media>> userList(ListStatus status) async => const [];

  @override
  Future<void> updateProgress(Media media, int episode) async {}
}
