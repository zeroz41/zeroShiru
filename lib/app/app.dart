import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/settings/providers.dart';
import '../domain/models/settings.dart';
import 'router.dart';
import 'theme/theme.dart';

class ZeroApp extends ConsumerWidget {
  const ZeroApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset =
        ref.watch(settingsControllerProvider).value?.themePreset ??
        AppThemePreset.standard;
    return MaterialApp.router(
      title: 'Zero',
      debugShowCheckedModeBanner: false,
      theme: ZeroThemeCatalog.fromId(preset).buildTheme(),
      themeAnimationDuration: const Duration(milliseconds: 240),
      themeAnimationCurve: Curves.easeOutCubic,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
