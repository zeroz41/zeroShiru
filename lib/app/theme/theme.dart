import 'package:flutter/material.dart';

import 'tokens.dart';

/// The Zero dark theme, built from [ZeroTokens].
///
/// Pages sit on top of the [AmbientBackground] wrapper, so most surfaces are
/// transparent or translucent panels; the scaffold base is `--dark-color`.
ThemeData buildZeroTheme() {
  const scheme = ColorScheme.dark(
    primary: ZeroTokens.accent,
    onPrimary: ZeroTokens.highlight,
    secondary: ZeroTokens.accentLight,
    onSecondary: ZeroTokens.highlight,
    tertiary: ZeroTokens.accentVeryLight,
    onTertiary: ZeroTokens.dark,
    surface: ZeroTokens.dark,
    onSurface: ZeroTokens.text,
    surfaceContainerHighest: ZeroTokens.darkVeryLight,
    surfaceContainerHigh: ZeroTokens.darkLight,
    surfaceContainerLowest: ZeroTokens.darkVeryDim,
    error: ZeroTokens.errorVeryLight,
    onError: ZeroTokens.highlight,
    outline: ZeroTokens.surfaceBorder,
    outlineVariant: ZeroTokens.grayLight,
  );

  const baseStyle = TextStyle(
    fontFamily: ZeroTokens.fontFamily,
    color: ZeroTokens.text,
    fontWeight: FontWeight.w400,
  );

  final textTheme = TextTheme(
    // Hero / details headlines: weight 900.
    displayLarge: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale50,
      fontWeight: FontWeight.w900,
      color: ZeroTokens.highlight,
      height: 1.06,
      letterSpacing: -0.02 * ZeroTokens.fontScale50,
    ),
    displayMedium: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale40,
      fontWeight: FontWeight.w900,
      color: ZeroTokens.highlight,
      height: 1.06,
      letterSpacing: -0.02 * ZeroTokens.fontScale40,
    ),
    displaySmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale34,
      fontWeight: FontWeight.w900,
      color: ZeroTokens.highlight,
      height: 1.1,
    ),
    // Rail/section titles.
    headlineMedium: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale24,
      fontWeight: FontWeight.w700,
      color: ZeroTokens.highlight,
    ),
    headlineSmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale20,
      fontWeight: FontWeight.w700,
      color: ZeroTokens.highlight,
    ),
    titleLarge: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale18,
      fontWeight: FontWeight.w700,
      color: ZeroTokens.highlight,
    ),
    titleMedium: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale16,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale14,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: baseStyle.copyWith(fontSize: ZeroTokens.fontScale16),
    bodyMedium: baseStyle.copyWith(fontSize: ZeroTokens.fontScale14),
    bodySmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontSize12,
      color: ZeroTokens.textMuted,
    ),
    labelLarge: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale14,
      fontWeight: FontWeight.w700,
    ),
    labelMedium: baseStyle.copyWith(
      fontSize: ZeroTokens.fontSize12,
      fontWeight: FontWeight.w600,
    ),
    labelSmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontSize12,
      fontWeight: FontWeight.w500,
      color: ZeroTokens.textMuted,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    fontFamily: ZeroTokens.fontFamily,
    textTheme: textTheme,
    scaffoldBackgroundColor: ZeroTokens.dark,
    canvasColor: ZeroTokens.dark,
    splashFactory: NoSplash.splashFactory,
    highlightColor: ZeroTokens.navPressWash,
    hoverColor: ZeroTokens.navHoverWash,
    focusColor: ZeroTokens.accent,
    dividerTheme: const DividerThemeData(
      color: ZeroTokens.surfaceBorder,
      thickness: 1,
      space: 1,
    ),
    iconTheme: const IconThemeData(color: ZeroTokens.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: ZeroTokens.darkVeryLight,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        border: Border.all(color: ZeroTokens.surfaceBorder),
        boxShadow: ZeroTokens.toastShadow,
      ),
      textStyle: baseStyle.copyWith(
        fontSize: ZeroTokens.fontSize12,
        color: ZeroTokens.text,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZeroTokens.darkVeryDim,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        side: const BorderSide(color: ZeroTokens.surfaceBorder),
      ),
      titleTextStyle: textTheme.headlineSmall,
      contentTextStyle: textTheme.bodyLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: ZeroTokens.darkLight,
      contentTextStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        side: const BorderSide(color: ZeroTokens.surfaceBorder),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(ZeroTokens.darkLight),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: const WidgetStatePropertyAll(Color(0xB3000000)),
        side: const WidgetStatePropertyAll(
          BorderSide(color: ZeroTokens.surfaceBorder),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
          ),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(vertical: ZeroTokens.space2),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(
      style: ButtonStyle(
        foregroundColor: const WidgetStatePropertyAll(ZeroTokens.text),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? ZeroTokens.navPressWash
              : ZeroTokens.navHoverWash,
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(
            horizontal: ZeroTokens.space4,
            vertical: ZeroTokens.space2,
          ),
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: ZeroTokens.darkVeryLight,
      selectedColor: const Color(0x527C3AED),
      disabledColor: const Color(0x4017191C),
      checkmarkColor: ZeroTokens.accentVeryLight,
      side: const BorderSide(color: ZeroTokens.surfaceBorder),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      ),
      labelStyle: textTheme.labelMedium,
      secondaryLabelStyle: textTheme.labelMedium?.copyWith(
        color: ZeroTokens.highlight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: ZeroTokens.space1),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ZeroTokens.highlight
              : ZeroTokens.textLight,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ZeroTokens.navPillGradTop
              : ZeroTokens.darkVeryLight,
        ),
        side: const WidgetStatePropertyAll(
          BorderSide(color: ZeroTokens.surfaceBorder),
        ),
        visualDensity: VisualDensity.compact,
      ),
    ),
    navigationRailTheme: const NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: ZeroTokens.accentVeryLight),
      unselectedIconTheme: IconThemeData(color: ZeroTokens.grayVeryDim),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: ZeroTokens.surfaceShell,
      indicatorColor: ZeroTokens.navPillGradTop,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ZeroTokens.accent,
        foregroundColor: ZeroTokens.highlight,
        minimumSize: const Size(0, ZeroTokens.buttonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: ZeroTokens.buttonPaddingX,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ZeroTokens.text,
        side: const BorderSide(color: ZeroTokens.surfaceBorder),
        minimumSize: const Size(0, ZeroTokens.buttonHeight),
        padding: const EdgeInsets.symmetric(
          horizontal: ZeroTokens.buttonPaddingX,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ZeroTokens.accentVeryLight,
        textStyle: textTheme.labelLarge,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZeroTokens.darkVeryLight,
      hintStyle: baseStyle.copyWith(color: ZeroTokens.textMuted),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: ZeroTokens.space3,
        vertical: ZeroTokens.space2,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        borderSide: const BorderSide(color: ZeroTokens.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        borderSide: const BorderSide(color: ZeroTokens.accent, width: 1.5),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6.1), // 0.8rem
      radius: const Radius.circular(ZeroTokens.radiusPill),
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
