import 'package:flutter/material.dart';

/// Placeholder dark theme. Will be replaced with tokens ported from the
/// Svelte design system (cinema hero / accent pills / soft posters look).
ThemeData buildShiruTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF7C4DFF),
    brightness: Brightness.dark,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: const Color(0xFF0B0B10),
  );
}
