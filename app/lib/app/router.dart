import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/playback/request.dart';
import '../domain/models/catalog.dart';
import '../domain/models/media.dart';
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
                pageBuilder: (context, state) => NoTransitionPage(
                  child: SearchPage(
                    key: ValueKey('search-${state.uri.query}'),
                    initialGenre: state.uri.queryParameters['genre'],
                    initialSort: _parseSort(state.uri.queryParameters['sort']),
                    initialSeason: _parseSeason(
                      state.uri.queryParameters['season'],
                    ),
                    initialYear: int.tryParse(
                      state.uri.queryParameters['year'] ?? '',
                    ),
                  ),
                ),
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
        builder: (context, state) {
          final extra = state.extra;
          return PlayerPage(
            initialSource: extra is PlayerFile ? extra : null,
            initialLaunch: extra is PlaybackLaunch ? extra : null,
          );
        },
      ),
    ],
  );
});

MediaSort? _parseSort(String? value) => switch (value) {
  'trending' => MediaSort.trending,
  'popularity' => MediaSort.popularity,
  'score' => MediaSort.score,
  'title' => MediaSort.title,
  'startDate' => MediaSort.startDate,
  _ => null,
};

MediaSeason? _parseSeason(String? value) => switch (value) {
  'winter' => MediaSeason.winter,
  'spring' => MediaSeason.spring,
  'summer' => MediaSeason.summer,
  'fall' => MediaSeason.fall,
  _ => null,
};
