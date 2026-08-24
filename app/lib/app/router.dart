import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models/torrent.dart';
import '../features/downloads/downloads_page.dart';
import '../features/home/home_page.dart';
import '../features/player/player_page.dart';
import '../features/schedule/schedule_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/settings_page.dart';
import 'shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(location: state.uri.path, child: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/home',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: HomePage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/search',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: SearchPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/schedule',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: SchedulePage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/downloads',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: DownloadsPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) =>
                    const NoTransitionPage(child: SettingsPage()),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/player',
        builder: (context, state) => PlayerPage(
          initialSource: state.extra is PlayerFile
              ? state.extra! as PlayerFile
              : null,
        ),
      ),
    ],
  );
});
