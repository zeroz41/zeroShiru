import 'package:flutter/material.dart';

/// Theme-dependent colors used by Zero's custom surfaces.
///
/// Material widgets consume the matching [ColorScheme]. Custom widgets use
/// this extension instead of global color constants, keeping every palette in
/// one place and making new themes a catalog-only change.
@immutable
class ZeroPalette extends ThemeExtension<ZeroPalette> {
  const ZeroPalette({
    required this.brightness,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.accentDim,
    required this.seekbarAccent,
    required this.background,
    required this.backgroundTop,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceModal,
    required this.shell,
    required this.panel,
    required this.panelStrong,
    required this.border,
    required this.surfaceHighlight,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.onAccent,
    required this.inactive,
    required this.success,
    required this.warning,
    required this.error,
    required this.navHover,
    required this.navPress,
    required this.navSelected,
    required this.navSelectedBorder,
    required this.cardHover,
    required this.cardHoverBorder,
    required this.ambientPrimary,
    required this.ambientSecondary,
    required this.emptyGlyph,
    required this.skeletonHighlight,
  });

  final Brightness brightness;
  final Color accent;
  final Color accentHover;
  final Color accentSoft;
  final Color accentDim;
  final Color seekbarAccent;
  final Color background;
  final Color backgroundTop;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceModal;
  final Color shell;
  final Color panel;
  final Color panelStrong;
  final Color border;
  final Color surfaceHighlight;
  final Color text;
  final Color textSecondary;
  final Color textMuted;
  final Color onAccent;
  final Color inactive;
  final Color success;
  final Color warning;
  final Color error;
  final Color navHover;
  final Color navPress;
  final Color navSelected;
  final Color navSelectedBorder;
  final Color cardHover;
  final Color cardHoverBorder;
  final Color ambientPrimary;
  final Color ambientSecondary;
  final Color emptyGlyph;
  final Color skeletonHighlight;

  bool get isLight => brightness == Brightness.light;

  /// Video always sits on a black canvas. A light app theme keeps its accent
  /// identity but swaps to dark control surfaces so captions and chrome stay
  /// legible over moving imagery.
  ZeroPalette get forPlayer {
    if (!isLight) return this;
    return copyWith(
      brightness: Brightness.dark,
      accentSoft: const Color(0xFFC4B5FD),
      background: Colors.black,
      backgroundTop: const Color(0xFF08090A),
      surface: const Color(0xFF202327),
      surfaceRaised: const Color(0xFF25272D),
      surfaceModal: const Color(0xFF090A0B),
      shell: const Color(0xF7121416),
      panel: const Color(0xD9202327),
      panelStrong: const Color(0xF0202327),
      border: const Color(0x2EFFFFFF),
      surfaceHighlight: const Color(0x12FFFFFF),
      text: const Color(0xE6FFFFFF),
      textSecondary: const Color(0xBFFFFFFF),
      textMuted: const Color(0xA6FFFFFF),
      inactive: const Color(0xFF73777E),
      success: const Color(0xFF69D454),
      warning: const Color(0xFFD3AE17),
      error: const Color(0xFFFF6B6B),
      navHover: const Color(0x1FFFFFFF),
      navPress: const Color(0x33FFFFFF),
      cardHover: const Color(0xF225272D),
      emptyGlyph: const Color(0x52FFFFFF),
      skeletonHighlight: const Color(0x14FFFFFF),
    );
  }

  List<BoxShadow> get navigationGlow => [
    BoxShadow(
      color: accent.withValues(alpha: isLight ? 0.13 : 0.16),
      offset: const Offset(0, 3.8),
      blurRadius: 12.3,
    ),
  ];

  List<BoxShadow> get ctaGlow => [
    BoxShadow(
      color: accent.withValues(alpha: isLight ? 0.25 : 0.45),
      offset: const Offset(0, 3.1),
      blurRadius: 13.8,
    ),
  ];

  List<BoxShadow> get cardShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.12 : 0.22),
      offset: const Offset(0, 6.1),
      blurRadius: 15.4,
    ),
  ];

  List<BoxShadow> get sidebarShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.12 : 0.32),
      offset: const Offset(9.2, 0),
      blurRadius: 23,
    ),
  ];

  List<BoxShadow> get bottomBarShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.12 : 0.35),
      offset: const Offset(0, -9.2),
      blurRadius: 23,
    ),
  ];

  List<BoxShadow> get feedLipShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.08 : 0.18),
      offset: const Offset(0, -9.2),
      blurRadius: 23,
    ),
  ];

  List<BoxShadow> get toastShadow => [
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.18 : 0.55),
      offset: const Offset(0, 6.1),
      blurRadius: 15.4,
    ),
  ];

  List<BoxShadow> liftShadow([Color? bloom]) => [
    BoxShadow(
      color: isLight
          ? Colors.white.withValues(alpha: 0.75)
          : Colors.white.withValues(alpha: 0.22),
      spreadRadius: 1.2,
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.24 : 0.75),
      offset: const Offset(0, 9.2),
      blurRadius: 18.4,
    ),
    BoxShadow(
      color: (bloom ?? accent).withValues(alpha: isLight ? 0.32 : 1),
      blurRadius: 23,
      spreadRadius: -4.6,
    ),
  ];

  List<BoxShadow> liftShadowSoft([Color? bloom]) => [
    BoxShadow(
      color: isLight
          ? Colors.white.withValues(alpha: 0.62)
          : Colors.white.withValues(alpha: 0.16),
      spreadRadius: 0.77,
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: isLight ? 0.18 : 0.60),
      offset: const Offset(0, 4.6),
      blurRadius: 10.8,
    ),
    BoxShadow(
      color: (bloom ?? accent).withValues(alpha: isLight ? 0.26 : 1),
      blurRadius: 15.4,
      spreadRadius: -4.6,
    ),
  ];

  @override
  ZeroPalette copyWith({
    Brightness? brightness,
    Color? accent,
    Color? accentHover,
    Color? accentSoft,
    Color? accentDim,
    Color? seekbarAccent,
    Color? background,
    Color? backgroundTop,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceModal,
    Color? shell,
    Color? panel,
    Color? panelStrong,
    Color? border,
    Color? surfaceHighlight,
    Color? text,
    Color? textSecondary,
    Color? textMuted,
    Color? onAccent,
    Color? inactive,
    Color? success,
    Color? warning,
    Color? error,
    Color? navHover,
    Color? navPress,
    Color? navSelected,
    Color? navSelectedBorder,
    Color? cardHover,
    Color? cardHoverBorder,
    Color? ambientPrimary,
    Color? ambientSecondary,
    Color? emptyGlyph,
    Color? skeletonHighlight,
  }) {
    return ZeroPalette(
      brightness: brightness ?? this.brightness,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentSoft: accentSoft ?? this.accentSoft,
      accentDim: accentDim ?? this.accentDim,
      seekbarAccent: seekbarAccent ?? this.seekbarAccent,
      background: background ?? this.background,
      backgroundTop: backgroundTop ?? this.backgroundTop,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceModal: surfaceModal ?? this.surfaceModal,
      shell: shell ?? this.shell,
      panel: panel ?? this.panel,
      panelStrong: panelStrong ?? this.panelStrong,
      border: border ?? this.border,
      surfaceHighlight: surfaceHighlight ?? this.surfaceHighlight,
      text: text ?? this.text,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      onAccent: onAccent ?? this.onAccent,
      inactive: inactive ?? this.inactive,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      error: error ?? this.error,
      navHover: navHover ?? this.navHover,
      navPress: navPress ?? this.navPress,
      navSelected: navSelected ?? this.navSelected,
      navSelectedBorder: navSelectedBorder ?? this.navSelectedBorder,
      cardHover: cardHover ?? this.cardHover,
      cardHoverBorder: cardHoverBorder ?? this.cardHoverBorder,
      ambientPrimary: ambientPrimary ?? this.ambientPrimary,
      ambientSecondary: ambientSecondary ?? this.ambientSecondary,
      emptyGlyph: emptyGlyph ?? this.emptyGlyph,
      skeletonHighlight: skeletonHighlight ?? this.skeletonHighlight,
    );
  }

  @override
  ZeroPalette lerp(covariant ZeroPalette? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return ZeroPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      accent: mix(accent, other.accent),
      accentHover: mix(accentHover, other.accentHover),
      accentSoft: mix(accentSoft, other.accentSoft),
      accentDim: mix(accentDim, other.accentDim),
      seekbarAccent: mix(seekbarAccent, other.seekbarAccent),
      background: mix(background, other.background),
      backgroundTop: mix(backgroundTop, other.backgroundTop),
      surface: mix(surface, other.surface),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      surfaceModal: mix(surfaceModal, other.surfaceModal),
      shell: mix(shell, other.shell),
      panel: mix(panel, other.panel),
      panelStrong: mix(panelStrong, other.panelStrong),
      border: mix(border, other.border),
      surfaceHighlight: mix(surfaceHighlight, other.surfaceHighlight),
      text: mix(text, other.text),
      textSecondary: mix(textSecondary, other.textSecondary),
      textMuted: mix(textMuted, other.textMuted),
      onAccent: mix(onAccent, other.onAccent),
      inactive: mix(inactive, other.inactive),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      error: mix(error, other.error),
      navHover: mix(navHover, other.navHover),
      navPress: mix(navPress, other.navPress),
      navSelected: mix(navSelected, other.navSelected),
      navSelectedBorder: mix(navSelectedBorder, other.navSelectedBorder),
      cardHover: mix(cardHover, other.cardHover),
      cardHoverBorder: mix(cardHoverBorder, other.cardHoverBorder),
      ambientPrimary: mix(ambientPrimary, other.ambientPrimary),
      ambientSecondary: mix(ambientSecondary, other.ambientSecondary),
      emptyGlyph: mix(emptyGlyph, other.emptyGlyph),
      skeletonHighlight: mix(skeletonHighlight, other.skeletonHighlight),
    );
  }
}

extension ZeroPaletteContext on BuildContext {
  ZeroPalette get zeroPalette {
    final palette = Theme.of(this).extension<ZeroPalette>();
    assert(palette != null, 'ZeroPalette is missing from ThemeData');
    return palette!;
  }
}
