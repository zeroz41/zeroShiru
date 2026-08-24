import 'package:flutter/material.dart';

import 'tokens.dart';

/// The zeroShiru dark theme, built from [ShiruTokens].
///
/// Pages sit on top of the [AmbientBackground] wrapper, so most surfaces are
/// transparent or translucent panels; the scaffold base is `--dark-color`.
ThemeData buildShiruTheme() {
  const scheme = ColorScheme.dark(
    primary: ShiruTokens.accent,
    onPrimary: ShiruTokens.highlight,
    secondary: ShiruTokens.accentLight,
    onSecondary: ShiruTokens.highlight,
    tertiary: ShiruTokens.accentVeryLight,
    onTertiary: ShiruTokens.dark,
    surface: ShiruTokens.dark,
    onSurface: ShiruTokens.text,
    surfaceContainerHighest: ShiruTokens.darkVeryLight,
    surfaceContainerHigh: ShiruTokens.darkLight,
    surfaceContainerLowest: ShiruTokens.darkVeryDim,
    error: ShiruTokens.errorVeryLight,
    onError: ShiruTokens.highlight,
    outline: ShiruTokens.surfaceBorder,
    outlineVariant: ShiruTokens.grayLight,
  );

  const baseStyle = TextStyle(
    fontFamily: ShiruTokens.fontFamily,
    color: ShiruTokens.text,
    fontWeight: FontWeight.w400,
  );

  final textTheme = TextTheme(
    // Hero / details headlines: weight 900.
    displayLarge: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale50,
      fontWeight: FontWeight.w900,
      color: ShiruTokens.highlight,
      height: 1.06,
      letterSpacing: -0.02 * ShiruTokens.fontScale50,
    ),
    displayMedium: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale40,
      fontWeight: FontWeight.w900,
      color: ShiruTokens.highlight,
      height: 1.06,
      letterSpacing: -0.02 * ShiruTokens.fontScale40,
    ),
    displaySmall: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale34,
      fontWeight: FontWeight.w900,
      color: ShiruTokens.highlight,
      height: 1.1,
    ),
    // Rail/section titles.
    headlineMedium: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale24,
      fontWeight: FontWeight.w700,
      color: ShiruTokens.highlight,
    ),
    headlineSmall: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale20,
      fontWeight: FontWeight.w700,
      color: ShiruTokens.highlight,
    ),
    titleLarge: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale18,
      fontWeight: FontWeight.w700,
      color: ShiruTokens.highlight,
    ),
    titleMedium: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale16,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale14,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: baseStyle.copyWith(fontSize: ShiruTokens.fontScale16),
    bodyMedium: baseStyle.copyWith(fontSize: ShiruTokens.fontScale14),
    bodySmall: baseStyle.copyWith(
      fontSize: ShiruTokens.fontSize12,
      color: ShiruTokens.textMuted,
    ),
    labelLarge: baseStyle.copyWith(
      fontSize: ShiruTokens.fontScale14,
      fontWeight: FontWeight.w700,
    ),
    labelMedium: baseStyle.copyWith(
      fontSize: ShiruTokens.fontSize12,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: baseStyle.copyWith(
      fontSize: ShiruTokens.fontSize12,
      fontWeight: FontWeight.w500,
      color: ShiruTokens.textMuted,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: ShiruTokens.fontFamily,
    textTheme: textTheme,
    scaffoldBackgroundColor: ShiruTokens.dark,
    canvasColor: ShiruTokens.dark,
    splashFactory: NoSplash.splashFactory,
    highlightColor: ShiruTokens.navPressWash,
    hoverColor: ShiruTokens.navHoverWash,
    focusColor: ShiruTokens.accent,
    dividerTheme: const DividerThemeData(
      color: ShiruTokens.surfaceBorder,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: ShiruTokens.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: ShiruTokens.darkVeryLight,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        border: Border.all(color: ShiruTokens.surfaceBorder),
        boxShadow: ShiruTokens.toastShadow,
      ),
      textStyle: baseStyle.copyWith(
        fontSize: ShiruTokens.fontSize12,
        color: ShiruTokens.text,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ShiruTokens.darkVeryDim,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
        side: const BorderSide(color: ShiruTokens.surfaceBorder),
      ),
      titleTextStyle: textTheme.headlineSmall,
      contentTextStyle: textTheme.bodyLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ShiruTokens.darkLight,
      contentTextStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
        side: const BorderSide(color: ShiruTokens.surfaceBorder),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: ShiruTokens.accentVeryLight),
      unselectedIconTheme: IconThemeData(color: ShiruTokens.grayVeryDim),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: ShiruTokens.surfaceShell,
      indicatorColor: ShiruTokens.navPillGradTop,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ShiruTokens.accent,
        foregroundColor: ShiruTokens.highlight,
        minimumSize: const Size(0, ShiruTokens.buttonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.buttonPaddingX,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ShiruTokens.text,
        side: const BorderSide(color: ShiruTokens.surfaceBorder),
        minimumSize: const Size(0, ShiruTokens.buttonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.buttonPaddingX,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ShiruTokens.accentVeryLight,
        textStyle: textTheme.labelLarge,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ShiruTokens.darkVeryLight,
      hintStyle: baseStyle.copyWith(color: ShiruTokens.textMuted),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: ShiruTokens.space3,
        vertical: ShiruTokens.space2,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        borderSide: const BorderSide(color: ShiruTokens.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        borderSide: const BorderSide(color: ShiruTokens.accent, width: 1.5),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6.1), // 0.8rem
      radius: const Radius.circular(ShiruTokens.radiusPill),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? const Color(0x52FFFFFF) // white .32
            : const Color(0x29FFFFFF), // white .16
      ),
      trackVisibility: WidgetStateProperty.all(false),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
