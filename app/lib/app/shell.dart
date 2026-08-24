import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const _destinations = [
    (path: '/home', icon: Icons.home_rounded, label: 'Home'),
    (path: '/search', icon: Icons.search_rounded, label: 'Search'),
    (path: '/downloads', icon: Icons.download_rounded, label: 'Downloads'),
    (path: '/settings', icon: Icons.settings_rounded, label: 'Settings'),
  ];

  @override
  Widget build(BuildContext context) {
    final selected =
        _destinations.indexWhere((d) => location.startsWith(d.path));
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: selected < 0 ? 0 : selected,
            onDestinationSelected: (i) =>
                context.go(_destinations[i].path),
            labelType: NavigationRailLabelType.all,
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  label: Text(d.label),
                ),
            ],
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
