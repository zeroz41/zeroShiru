import 'package:flutter/material.dart';

import '../../domain/models/settings.dart';
import 'palette.dart';
import 'tokens.dart';

/// A discoverable entry in the built-in theme catalog.
@immutable
class ZeroThemeDefinition {
  const ZeroThemeDefinition({
    required this.id,
    required this.label,
    required this.description,
    required this.palette,
  });

  final AppThemePreset id;
  final String label;
  final String description;
  final ZeroPalette palette;

  ThemeData buildTheme() => buildZeroTheme(palette);
}

/// The single registry for themes shown in Settings and understood by the app.
/// Adding a theme means adding one enum value and one definition here.
abstract final class ZeroThemeCatalog {
  static const standard = ZeroThemeDefinition(
    id: AppThemePreset.standard,
    label: 'Default',
    description: 'Zero’s original charcoal and violet palette.',
    palette: _standardPalette,
  );

  static const crimson = ZeroThemeDefinition(
    id: AppThemePreset.crimson,
    label: 'Crimson',
    description: 'Deep charcoal surfaces with a vivid red accent.',
    palette: _crimsonPalette,
  );

  static const oled = ZeroThemeDefinition(
    id: AppThemePreset.oled,
    label: 'OLED',
    description: 'True black backgrounds for OLED displays.',
    palette: _oledPalette,
  );

  static const light = ZeroThemeDefinition(
    id: AppThemePreset.light,
    label: 'Light',
    description: 'A bright, low-glare palette with violet accents.',
    palette: _lightPalette,
  );

  static const midnight = ZeroThemeDefinition(
    id: AppThemePreset.midnight,
    label: 'Midnight Blue',
    description: 'Cool blue-gray surfaces inspired by your editor.',
    palette: _midnightPalette,
  );

  static const catppuccinMocha = ZeroThemeDefinition(
    id: AppThemePreset.catppuccinMocha,
    label: 'Catppuccin Mocha',
    description: 'Cozy navy surfaces with soft pastel accents.',
    palette: _catppuccinMochaPalette,
  );

  static const gruvboxDark = ZeroThemeDefinition(
    id: AppThemePreset.gruvboxDark,
    label: 'Gruvbox Dark',
    description: 'Warm retro browns with orange and golden accents.',
    palette: _gruvboxDarkPalette,
  );

  static const solarizedDark = ZeroThemeDefinition(
    id: AppThemePreset.solarizedDark,
    label: 'Solarized Dark',
    description: 'Low-glare deep teal with precise cyan accents.',
    palette: _solarizedDarkPalette,
  );

  static const everforestDark = ZeroThemeDefinition(
    id: AppThemePreset.everforestDark,
    label: 'Everforest Dark',
    description: 'Soft forest greens with warm, natural contrast.',
    palette: _everforestDarkPalette,
  );

  static const values = [
    standard,
    crimson,
    oled,
    light,
    midnight,
    catppuccinMocha,
    gruvboxDark,
    solarizedDark,
    everforestDark,
  ];

  static ZeroThemeDefinition fromId(AppThemePreset id) =>
      values.firstWhere((theme) => theme.id == id, orElse: () => standard);
}

/// Builds Material's component themes from one custom color palette.
///
/// [buildZeroTheme] remains callable without arguments for tests, previews,
/// and embedders that want the original theme.
ThemeData buildZeroTheme([ZeroPalette palette = _standardPalette]) {
  final scheme = ColorScheme(
    brightness: palette.brightness,
    primary: palette.accent,
    onPrimary: palette.onAccent,
    secondary: palette.accentHover,
    onSecondary: palette.onAccent,
    tertiary: palette.accentSoft,
    onTertiary: palette.isLight ? palette.onAccent : palette.background,
    error: palette.error,
    onError: palette.onAccent,
    surface: palette.surface,
    onSurface: palette.text,
    surfaceContainerHighest: palette.surfaceRaised,
    surfaceContainerHigh: palette.surface,
    surfaceContainerLowest: palette.background,
    outline: palette.border,
    outlineVariant: palette.inactive,
  );

  final baseStyle = TextStyle(
    fontFamily: ZeroTokens.fontFamily,
    color: palette.text,
    fontWeight: FontWeight.w400,
  );

  final textTheme = TextTheme(
    displayLarge: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale50,
      fontWeight: FontWeight.w900,
      color: palette.text,
      height: 1.06,
      letterSpacing: -0.02 * ZeroTokens.fontScale50,
    ),
    displayMedium: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale40,
      fontWeight: FontWeight.w900,
      color: palette.text,
      height: 1.06,
      letterSpacing: -0.02 * ZeroTokens.fontScale40,
    ),
    displaySmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale34,
      fontWeight: FontWeight.w900,
      color: palette.text,
      height: 1.1,
    ),
    headlineMedium: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale24,
      fontWeight: FontWeight.w700,
      color: palette.text,
    ),
    headlineSmall: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale20,
      fontWeight: FontWeight.w700,
      color: palette.text,
    ),
    titleLarge: baseStyle.copyWith(
      fontSize: ZeroTokens.fontScale18,
      fontWeight: FontWeight.w700,
      color: palette.text,
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
      color: palette.textMuted,
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
      color: palette.textMuted,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: palette.brightness,
    colorScheme: scheme,
    extensions: [palette],
    fontFamily: ZeroTokens.fontFamily,
    textTheme: textTheme,
    scaffoldBackgroundColor: palette.background,
    canvasColor: palette.background,
    splashFactory: NoSplash.splashFactory,
    highlightColor: palette.navPress,
    hoverColor: palette.navHover,
    focusColor: palette.accent,
    dividerTheme: DividerThemeData(
      color: palette.border,
      thickness: 1,
      space: 1,
    ),
    iconTheme: IconThemeData(color: palette.text),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        border: Border.all(color: palette.border),
        boxShadow: palette.toastShadow,
      ),
      textStyle: baseStyle.copyWith(
        fontSize: ZeroTokens.fontSize12,
        color: palette.text,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surfaceModal,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        side: BorderSide(color: palette.border),
      ),
      titleTextStyle: textTheme.headlineSmall,
      contentTextStyle: textTheme.bodyLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.surface,
      contentTextStyle: textTheme.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        side: BorderSide(color: palette.border),
      ),
      behavior: SnackBarBehavior.floating,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surface),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: WidgetStatePropertyAll(
          Colors.black.withValues(alpha: palette.isLight ? 0.22 : 0.70),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: palette.border)),
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
        foregroundColor: WidgetStatePropertyAll(palette.text),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? palette.navPress
              : palette.navHover,
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
      backgroundColor: palette.surfaceRaised,
      selectedColor: palette.navSelected,
      disabledColor: palette.surfaceHighlight,
      checkmarkColor: palette.accentSoft,
      side: BorderSide(color: palette.border),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      ),
      labelStyle: textTheme.labelMedium,
      secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: palette.text),
      padding: const EdgeInsets.symmetric(horizontal: ZeroTokens.space1),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.text
              : palette.textSecondary,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.navSelected
              : palette.surfaceRaised,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: palette.border)),
        visualDensity: VisualDensity.compact,
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: palette.accentSoft),
      unselectedIconTheme: IconThemeData(color: palette.inactive),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: palette.shell,
      indicatorColor: palette.navSelected,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? palette.onAccent : null,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : palette.surfaceRaised,
      ),
      trackOutlineColor: WidgetStatePropertyAll(palette.border),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
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
        foregroundColor: palette.text,
        side: BorderSide(color: palette.border),
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
        foregroundColor: palette.accentSoft,
        textStyle: textTheme.labelLarge,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceRaised,
      hintStyle: baseStyle.copyWith(color: palette.textMuted),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: ZeroTokens.space3,
        vertical: ZeroTokens.space2,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        borderSide: BorderSide(color: palette.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(6.1),
      radius: const Radius.circular(ZeroTokens.radiusPill),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => palette.text.withValues(
          alpha: states.contains(WidgetState.hovered) ? 0.32 : 0.16,
        ),
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

const _standardPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFF7C3AED),
  accentHover: Color(0xFF9F67FF),
  accentSoft: Color(0xFFC4B5FD),
  accentDim: Color(0xFF4C1D95),
  seekbarAccent: Color(0xFFE5204C),
  background: Color(0xFF17191C),
  backgroundTop: Color(0xFF121416),
  surface: Color(0xFF202327),
  surfaceRaised: Color(0xFF25272D),
  surfaceModal: Color(0xFF090A0B),
  shell: Color(0xF7121416),
  panel: Color(0xB8202327),
  panelStrong: Color(0xEB202327),
  border: Color(0x1CFFFFFF),
  surfaceHighlight: Color(0x0EFFFFFF),
  text: Color(0xCCFFFFFF),
  textSecondary: Color(0xA6FFFFFF),
  textMuted: Color(0x99FFFFFF),
  onAccent: Color(0xFFFFFFFF),
  inactive: Color(0xFF55585E),
  success: Color(0xFF69D454),
  warning: Color(0xFFD3AE17),
  error: Color(0xFFFF6B6B),
  navHover: Color(0x1AFFFFFF),
  navPress: Color(0x29FFFFFF),
  navSelected: Color(0x6B7C3AED),
  navSelectedBorder: Color(0x807C3AED),
  cardHover: Color(0xCC202327),
  cardHoverBorder: Color(0x6B7C3AED),
  ambientPrimary: Color(0x2B7C3AED),
  ambientSecondary: Color(0x14E5204C),
  emptyGlyph: Color(0x47FFFFFF),
  skeletonHighlight: Color(0x0FFFFFFF),
);

const _crimsonPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFFE5204C),
  accentHover: Color(0xFFFF5678),
  accentSoft: Color(0xFFFFA6B9),
  accentDim: Color(0xFF8B1731),
  seekbarAccent: Color(0xFFFF4267),
  background: Color(0xFF1D1719),
  backgroundTop: Color(0xFF171113),
  surface: Color(0xFF292125),
  surfaceRaised: Color(0xFF30262B),
  surfaceModal: Color(0xFF0F090B),
  shell: Color(0xF7171113),
  panel: Color(0xC2292125),
  panelStrong: Color(0xF0292125),
  border: Color(0x24FFFFFF),
  surfaceHighlight: Color(0x10FFFFFF),
  text: Color(0xE6FFFFFF),
  textSecondary: Color(0xB8FFFFFF),
  textMuted: Color(0x99FFFFFF),
  onAccent: Color(0xFFFFFFFF),
  inactive: Color(0xFF705A62),
  success: Color(0xFF69D454),
  warning: Color(0xFFE2B72B),
  error: Color(0xFFFF6B6B),
  navHover: Color(0x1AFFFFFF),
  navPress: Color(0x29FFFFFF),
  navSelected: Color(0x66E5204C),
  navSelectedBorder: Color(0x99E5204C),
  cardHover: Color(0xE6302429),
  cardHoverBorder: Color(0x8AE5204C),
  ambientPrimary: Color(0x3DE5204C),
  ambientSecondary: Color(0x14FF8A4C),
  emptyGlyph: Color(0x47FFFFFF),
  skeletonHighlight: Color(0x12FFFFFF),
);

const _oledPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFF8B5CF6),
  accentHover: Color(0xFFA78BFA),
  accentSoft: Color(0xFFC4B5FD),
  accentDim: Color(0xFF4C1D95),
  seekbarAccent: Color(0xFFE5204C),
  background: Color(0xFF000000),
  backgroundTop: Color(0xFF000000),
  surface: Color(0xFF0A0A0A),
  surfaceRaised: Color(0xFF141414),
  surfaceModal: Color(0xFF050505),
  shell: Color(0xFA000000),
  panel: Color(0xE60A0A0A),
  panelStrong: Color(0xF20A0A0A),
  border: Color(0x2BFFFFFF),
  surfaceHighlight: Color(0x12FFFFFF),
  text: Color(0xE6FFFFFF),
  textSecondary: Color(0xBFFFFFFF),
  textMuted: Color(0xA6FFFFFF),
  onAccent: Color(0xFFFFFFFF),
  inactive: Color(0xFF6B6B6B),
  success: Color(0xFF69D454),
  warning: Color(0xFFE2B72B),
  error: Color(0xFFFF6B6B),
  navHover: Color(0x1FFFFFFF),
  navPress: Color(0x33FFFFFF),
  navSelected: Color(0x668B5CF6),
  navSelectedBorder: Color(0xA68B5CF6),
  cardHover: Color(0xF2121212),
  cardHoverBorder: Color(0x8F8B5CF6),
  ambientPrimary: Color(0x1F8B5CF6),
  ambientSecondary: Color(0x0FE5204C),
  emptyGlyph: Color(0x52FFFFFF),
  skeletonHighlight: Color(0x14FFFFFF),
);

const _lightPalette = ZeroPalette(
  brightness: Brightness.light,
  accent: Color(0xFF6D28D9),
  accentHover: Color(0xFF7C3AED),
  accentSoft: Color(0xFF5B21B6),
  accentDim: Color(0xFF4C1D95),
  seekbarAccent: Color(0xFFD71945),
  background: Color(0xFFF6F7FB),
  backgroundTop: Color(0xFFE9EDF5),
  surface: Color(0xFFFFFFFF),
  surfaceRaised: Color(0xFFEEF1F6),
  surfaceModal: Color(0xFFFFFFFF),
  shell: Color(0xFAFFFFFF),
  panel: Color(0xEFFFFFFF),
  panelStrong: Color(0xFAFFFFFF),
  border: Color(0x24151A24),
  surfaceHighlight: Color(0x0F151A24),
  text: Color(0xE6151A24),
  textSecondary: Color(0xB8151A24),
  textMuted: Color(0x99151A24),
  onAccent: Color(0xFFFFFFFF),
  inactive: Color(0xFF737987),
  success: Color(0xFF237A18),
  warning: Color(0xFF8A6510),
  error: Color(0xFFB42318),
  navHover: Color(0x0F6D28D9),
  navPress: Color(0x1F6D28D9),
  navSelected: Color(0x246D28D9),
  navSelectedBorder: Color(0x666D28D9),
  cardHover: Color(0xFFFFFFFF),
  cardHoverBorder: Color(0x806D28D9),
  ambientPrimary: Color(0x1F6D28D9),
  ambientSecondary: Color(0x14D71945),
  emptyGlyph: Color(0x52151A24),
  skeletonHighlight: Color(0x14FFFFFF),
);

const _midnightPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFF4D9FFF),
  accentHover: Color(0xFF75B7FF),
  accentSoft: Color(0xFFA6D2FF),
  accentDim: Color(0xFF1C5A9F),
  seekbarAccent: Color(0xFF49D58A),
  background: Color(0xFF1E2532),
  backgroundTop: Color(0xFF171D28),
  surface: Color(0xFF252E3D),
  surfaceRaised: Color(0xFF2C3748),
  surfaceModal: Color(0xFF101722),
  shell: Color(0xF7171D28),
  panel: Color(0xC2252E3D),
  panelStrong: Color(0xF0252E3D),
  border: Color(0x244D6685),
  surfaceHighlight: Color(0x125B789C),
  text: Color(0xE6D8E2F0),
  textSecondary: Color(0xBFC2CDDC),
  textMuted: Color(0xA69CAABC),
  onAccent: Color(0xFF08111E),
  inactive: Color(0xFF65748A),
  success: Color(0xFF49D58A),
  warning: Color(0xFFE6C15A),
  error: Color(0xFFFF7188),
  navHover: Color(0x1A8DBEFF),
  navPress: Color(0x298DBEFF),
  navSelected: Color(0x524D9FFF),
  navSelectedBorder: Color(0x8F4D9FFF),
  cardHover: Color(0xE62C3748),
  cardHoverBorder: Color(0x8F4D9FFF),
  ambientPrimary: Color(0x334D9FFF),
  ambientSecondary: Color(0x1749D58A),
  emptyGlyph: Color(0x527FA6D3),
  skeletonHighlight: Color(0x1275B7FF),
);

const _catppuccinMochaPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFFCBA6F7),
  accentHover: Color(0xFFDDB6F2),
  accentSoft: Color(0xFFB4BEFE),
  accentDim: Color(0xFF6C4F85),
  seekbarAccent: Color(0xFFF38BA8),
  background: Color(0xFF1E1E2E),
  backgroundTop: Color(0xFF181825),
  surface: Color(0xFF313244),
  surfaceRaised: Color(0xFF45475A),
  surfaceModal: Color(0xFF11111B),
  shell: Color(0xFA11111B),
  panel: Color(0xC2313244),
  panelStrong: Color(0xF0313244),
  border: Color(0x526C7086),
  surfaceHighlight: Color(0x33585B70),
  text: Color(0xFFCDD6F4),
  textSecondary: Color(0xFFBAC2DE),
  textMuted: Color(0xFFA6ADC8),
  onAccent: Color(0xFF1E1E2E),
  inactive: Color(0xFF6C7086),
  success: Color(0xFFA6E3A1),
  warning: Color(0xFFF9E2AF),
  error: Color(0xFFF38BA8),
  navHover: Color(0x1FB4BEFE),
  navPress: Color(0x33B4BEFE),
  navSelected: Color(0x59CBA6F7),
  navSelectedBorder: Color(0xA6CBA6F7),
  cardHover: Color(0xF045475A),
  cardHoverBorder: Color(0x99CBA6F7),
  ambientPrimary: Color(0x33CBA6F7),
  ambientSecondary: Color(0x1A94E2D5),
  emptyGlyph: Color(0x8C7F849C),
  skeletonHighlight: Color(0x1FB4BEFE),
);

const _gruvboxDarkPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFFFE8019),
  accentHover: Color(0xFFFABD2F),
  accentSoft: Color(0xFFFBCF75),
  accentDim: Color(0xFFD65D0E),
  seekbarAccent: Color(0xFFFB4934),
  background: Color(0xFF282828),
  backgroundTop: Color(0xFF1D2021),
  surface: Color(0xFF3C3836),
  surfaceRaised: Color(0xFF504945),
  surfaceModal: Color(0xFF1D2021),
  shell: Color(0xFA1D2021),
  panel: Color(0xC23C3836),
  panelStrong: Color(0xF03C3836),
  border: Color(0x527C6F64),
  surfaceHighlight: Color(0x33665C54),
  text: Color(0xFFEBDBB2),
  textSecondary: Color(0xFFD5C4A1),
  textMuted: Color(0xFFA89984),
  onAccent: Color(0xFF1D2021),
  inactive: Color(0xFF7C6F64),
  success: Color(0xFFB8BB26),
  warning: Color(0xFFFABD2F),
  error: Color(0xFFFB4934),
  navHover: Color(0x1FFBF1C7),
  navPress: Color(0x33FBF1C7),
  navSelected: Color(0x59FE8019),
  navSelectedBorder: Color(0xA6FE8019),
  cardHover: Color(0xF0504945),
  cardHoverBorder: Color(0x99FE8019),
  ambientPrimary: Color(0x33FE8019),
  ambientSecondary: Color(0x1A8EC07C),
  emptyGlyph: Color(0x8CA89984),
  skeletonHighlight: Color(0x1FFABD2F),
);

const _solarizedDarkPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFF2AA198),
  accentHover: Color(0xFF42BDB4),
  accentSoft: Color(0xFF5FCAC2),
  accentDim: Color(0xFF176C66),
  seekbarAccent: Color(0xFFCB4B16),
  background: Color(0xFF002B36),
  backgroundTop: Color(0xFF001F27),
  surface: Color(0xFF073642),
  surfaceRaised: Color(0xFF124652),
  surfaceModal: Color(0xFF001F27),
  shell: Color(0xFA001F27),
  panel: Color(0xC2073642),
  panelStrong: Color(0xF0073642),
  border: Color(0x66586E75),
  surfaceHighlight: Color(0x33586E75),
  text: Color(0xFF93A1A1),
  textSecondary: Color(0xFF839496),
  textMuted: Color(0xFF657B83),
  onAccent: Color(0xFF002B36),
  inactive: Color(0xFF586E75),
  success: Color(0xFF859900),
  warning: Color(0xFFB58900),
  error: Color(0xFFDC322F),
  navHover: Color(0x1F2AA198),
  navPress: Color(0x332AA198),
  navSelected: Color(0x592AA198),
  navSelectedBorder: Color(0xA62AA198),
  cardHover: Color(0xF0124652),
  cardHoverBorder: Color(0x992AA198),
  ambientPrimary: Color(0x332AA198),
  ambientSecondary: Color(0x1A268BD2),
  emptyGlyph: Color(0x8C586E75),
  skeletonHighlight: Color(0x1F2AA198),
);

const _everforestDarkPalette = ZeroPalette(
  brightness: Brightness.dark,
  accent: Color(0xFFA7C080),
  accentHover: Color(0xFFB7CF8D),
  accentSoft: Color(0xFF83C092),
  accentDim: Color(0xFF425047),
  seekbarAccent: Color(0xFFE67E80),
  background: Color(0xFF2D353B),
  backgroundTop: Color(0xFF232A2E),
  surface: Color(0xFF343F44),
  surfaceRaised: Color(0xFF3D484D),
  surfaceModal: Color(0xFF232A2E),
  shell: Color(0xFA232A2E),
  panel: Color(0xC2343F44),
  panelStrong: Color(0xF0343F44),
  border: Color(0x66859289),
  surfaceHighlight: Color(0x33475258),
  text: Color(0xFFD3C6AA),
  textSecondary: Color(0xFF9DA9A0),
  textMuted: Color(0xFF859289),
  onAccent: Color(0xFF232A2E),
  inactive: Color(0xFF7A8478),
  success: Color(0xFFA7C080),
  warning: Color(0xFFDBBC7F),
  error: Color(0xFFE67E80),
  navHover: Color(0x1F83C092),
  navPress: Color(0x3383C092),
  navSelected: Color(0x59A7C080),
  navSelectedBorder: Color(0xA6A7C080),
  cardHover: Color(0xF03D484D),
  cardHoverBorder: Color(0x99A7C080),
  ambientPrimary: Color(0x33A7C080),
  ambientSecondary: Color(0x1A7FBBB3),
  emptyGlyph: Color(0x8C859289),
  skeletonHighlight: Color(0x1F83C092),
);
