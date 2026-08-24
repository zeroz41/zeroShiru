import 'package:flutter/widgets.dart';

/// Design tokens ported from the Svelte app's CSS custom properties.
///
/// All rem values from the old stylesheets are converted at the base scale of
/// **7.68 px per rem** (`--default-html-font-size: 48%`), the <1600px tier.
/// See docs/porting/design-map.md §1.1.
abstract final class ShiruTokens {
  // ---------------------------------------------------------------------------
  // rem conversion
  // ---------------------------------------------------------------------------

  /// 1rem in logical pixels at the base (<1600px) tier.
  static const double remPx = 7.68;

  /// Convert a rem measurement from the old CSS into logical pixels.
  static double rem(double value) => value * remPx;

  // ---------------------------------------------------------------------------
  // Colors — two accents! #E5204C is the seekbar ONLY; #2F75E4 is the app.
  // ---------------------------------------------------------------------------

  /// `--accent-color`. Seekbar progress + thumb only. User-overridable.
  static const Color seekbarAccent = Color(0xFFE5204C);

  /// `--tertiary-color`. The real UI accent: hero CTA, active nav pill,
  /// rail title tab, focus ring, favourite glow, ambient bloom, card hover.
  static const Color accent = Color(0xFF2F75E4);

  /// `--tertiary-color-light`. CTA hover, rail-tab gradient top.
  static const Color accentLight = Color(0xFF5D93EA);

  /// `--tertiary-color-very-light`. Active nav icon, section-title hover.
  static const Color accentVeryLight = Color(0xFFA0C0F3);

  /// `--tertiary-color-dim`. Link hover.
  static const Color accentDim = Color(0xFF123F87);

  /// `--highlight-color`. On-accent text, active nav label.
  static const Color highlight = Color(0xFFFFFFFF);

  /// `--dark-color`. Page base.
  static const Color dark = Color(0xFF17191C);

  /// `--dark-color-light`. Panels, toast bg.
  static const Color darkLight = Color(0xFF202327);

  /// `--dark-color-very-light`. Raised inputs, hover.
  static const Color darkVeryLight = Color(0xFF25272D);

  /// `--dark-color-dim`. Shell/chrome, top of the page gradient.
  static const Color darkDim = Color(0xFF121416);

  /// `--dark-color-very-dim`. Modal surfaces (`bg-very-dark`).
  static const Color darkVeryDim = Color(0xFF090A0B);

  /// `--gray-color-light`. Muted text, borders.
  static const Color grayLight = Color(0xFF40464F);

  /// `--gray-color-very-dim`. Inactive nav icon/label.
  static const Color grayVeryDim = Color(0xFF55585E);

  /// `--white-color-dim`. Icon hover.
  static const Color whiteDim = Color(0xFF999999);

  /// `--white-color-very-dim`. Dim icon hover.
  static const Color whiteVeryDim = Color(0xFF808080);

  /// `--primary-color`. btn-primary, dropdown checkmarks.
  static const Color primary = Color(0xFF1A90FF);

  /// `--primary-color-light`. btn-primary hover.
  static const Color primaryLight = Color(0xFF4DA9FF);

  /// `--completed-color`. Watched/completed.
  static const Color completed = Color(0xFF69D454);

  /// `--completed-color-dim`. Seekbar accent when the episode is completed.
  static const Color completedDim = Color(0xFF40AB2B);

  /// `--warning-color`.
  static const Color warning = Color(0xFFD3AE17);

  /// `--warning-color-very-dim`. Warning alert text.
  static const Color warningVeryDim = Color(0xFF57470A);

  /// `--error-color` / `-light` / `-very-light`.
  static const Color error = Color(0xFF480404);
  static const Color errorLight = Color(0xFF780707);
  static const Color errorVeryLight = Color(0xFFA90A0A);

  /// `--green-color` / `--green-color-light`. "AIRING" badge.
  static const Color green = Color(0xFF208A00);
  static const Color greenLight = Color(0xFF30CC00);

  /// `--octonary-color`. "Show My Anime" toggle, gain-boost state.
  static const Color octonary = Color(0xFFFF6B35);

  /// Service chrome.
  static const Color myAnimeList = Color(0xFF2C51A0);
  static const Color aniList = Color(0xFF283343);

  /// List-status dot colors.
  static const Color statusCurrent = Color(0xFF3DB4F2);
  static const Color statusPlanning = Color(0xFFF79A63);
  static const Color statusPaused = Color(0xFFFA7A7A);
  static const Color statusRepeating = Color(0xFF3BAEEA);
  static const Color statusDropped = Color(0xFFE85D75);
  static const Color statusNotify = Color(0xFFAF68FA);

  // ---------------------------------------------------------------------------
  // Text on dark
  // ---------------------------------------------------------------------------

  static const double textOpacity = 0.80;
  static const double textLightOpacity = 0.65;
  static const double textMutedOpacity = 0.60;

  static const Color text = Color(0xCCFFFFFF); // rgba(255,255,255,.80)
  static const Color textLight = Color(0xA6FFFFFF); // rgba(255,255,255,.65)
  static const Color textMuted = Color(0x99FFFFFF); // rgba(255,255,255,.60)

  // ---------------------------------------------------------------------------
  // Composite surfaces
  // ---------------------------------------------------------------------------

  /// `--surface-shell` rgba(18,20,22,.97) — sidebar/bottombar base.
  static const Color surfaceShell = Color(0xF7121416);

  /// `--surface-panel` rgba(32,35,39,.72) — card/panel top of gradient.
  static const Color surfacePanel = Color(0xB8202327);

  /// `--surface-panel-strong` rgba(32,35,39,.92).
  static const Color surfacePanelStrong = Color(0xEB202327);

  /// `--surface-border` rgba(255,255,255,.11) — every hairline in the app.
  static const Color surfaceBorder = Color(0x1CFFFFFF);

  /// `--surface-highlight` rgba(255,255,255,.055) — rail-top wash.
  static const Color surfaceHighlight = Color(0x0EFFFFFF);

  // ---------------------------------------------------------------------------
  // Corner radii (rem → px @7.68)
  // ---------------------------------------------------------------------------

  static const double radiusBase = 4.6; // 0.6rem — buttons, inputs
  static const double radiusPosterArt = 6.9; // 0.9rem — poster artwork
  static const double radiusPanel = 7.7; // 1.0rem — toasts, panels
  static const double radiusCard = 9.6; // 1.25rem — small card container
  static const double radiusBrand = 10.4; // 1.35rem — brand mark
  static const double radiusSurfaceTop = 18.4; // 2.4rem — feed/results lip
  static const double radiusPill = 999; // 5rem — pills/CTAs, fully round

  // ---------------------------------------------------------------------------
  // Spacing ladder (0.5/1/1.5/2/2.5/3/4 rem)
  // ---------------------------------------------------------------------------

  static const double space1 = 3.8;
  static const double space2 = 7.7;
  static const double space3 = 11.5;
  static const double space4 = 15.4;
  static const double space5 = 19.2;
  static const double space6 = 23.0;
  static const double space7 = 30.7;

  // ---------------------------------------------------------------------------
  // Fixed geometry
  // ---------------------------------------------------------------------------

  /// Sidebar width (7rem) — also the mobile bottombar height.
  static const double sidebarWidth = 54;

  /// Sidebar expanded-on-hover width (22rem).
  static const double sidebarExpandedWidth = 169;

  /// Breakpoint: >=769px = desktop left rail, <769px = mobile bottom bar.
  static const double desktopBreakpoint = 769;

  /// Nav button 3.1rem, nav link height 5.5rem.
  static const double navButtonSize = 23.8;
  static const double navLinkHeight = 42.2;

  /// Brand mark 5rem square.
  static const double brandMarkSize = 38.4;

  /// Button height 3.2rem, horizontal padding 1.5rem.
  static const double buttonHeight = 24.6;
  static const double buttonPaddingX = 11.5;

  // ---------------------------------------------------------------------------
  // Type ladder (rem → px @7.68), Nunito
  // ---------------------------------------------------------------------------

  static const String fontFamily = 'Nunito';
  static const String fontFamilyStats = 'Roboto'; // subtitles / player stats

  static const double fontSize12 = 9.2; // 1.2rem — nav labels
  static const double fontScale14 = 10.8;
  static const double fontScale16 = 12.3;
  static const double fontScale18 = 13.8;
  static const double fontScale20 = 15.4;
  static const double fontScale24 = 18.4; // rail titles
  static const double fontScale34 = 26.1;
  static const double fontScale40 = 30.7; // details H1
  static const double fontScale50 = 38.4;

  // ---------------------------------------------------------------------------
  // Motion — five durations, two curves. NEVER invent per-widget timings.
  // ---------------------------------------------------------------------------

  /// `--motion-press` 0.09s — global press.
  static const Duration motionPress = Duration(milliseconds: 90);

  /// `--motion-quick` 0.12s — nav links.
  static const Duration motionQuick = Duration(milliseconds: 120);

  /// `--motion` 0.16s — app-wide default.
  static const Duration motion = Duration(milliseconds: 160);

  /// `--motion-panel` 0.24s — sidebar width, modal open/close.
  static const Duration motionPanel = Duration(milliseconds: 240);

  /// Page transition fade, 0.18s ease-out, opacity .4→1.
  static const Duration motionPageFade = Duration(milliseconds: 180);

  /// `--ease-settle` cubic-bezier(.16,.84,.34,1) — fast off the mark,
  /// slow to stop.
  static const Curve easeSettle = Cubic(0.16, 0.84, 0.34, 1);

  /// `--ease-press` cubic-bezier(.2,0,0,1).
  static const Curve easePress = Cubic(0.2, 0, 0, 1);

  /// Skeleton sweep: 1s infinite cubic-bezier(.4,0,.2,1).
  static const Duration skeletonSweep = Duration(seconds: 1);
  static const Curve skeletonCurve = Cubic(0.4, 0, 0.2, 1);
  static const Color skeletonHighlight = Color(0x0FFFFFFF); // white .06

  // ---------------------------------------------------------------------------
  // Shadows — painted once and faded via opacity, never transitioned.
  // ---------------------------------------------------------------------------

  /// `--lift-shadow`: thin light rim + deep shadow + artwork-tinted bloom.
  /// [liftColor] comes from AniList `coverImage.color`, fallback [accent].
  static List<BoxShadow> liftShadow([Color? liftColor]) => [
        const BoxShadow(
          color: Color(0x38FFFFFF), // rgba(255,255,255,.22) rim
          spreadRadius: 1.2, // .15rem
        ),
        const BoxShadow(
          color: Color(0xBF000000), // rgba(0,0,0,.75)
          offset: Offset(0, 9.2), // 1.2rem
          blurRadius: 18.4, // 2.4rem
        ),
        BoxShadow(
          color: liftColor ?? accent, // 0 0 3rem -.6rem bloom
          blurRadius: 23,
          spreadRadius: -4.6,
        ),
      ];

  /// `--lift-shadow-soft`.
  static List<BoxShadow> liftShadowSoft([Color? liftColor]) => [
        const BoxShadow(
          color: Color(0x29FFFFFF), // rgba(255,255,255,.16) rim
          spreadRadius: 0.77, // .1rem
        ),
        const BoxShadow(
          color: Color(0x99000000), // rgba(0,0,0,.6)
          offset: Offset(0, 4.6), // .6rem
          blurRadius: 10.8, // 1.4rem
        ),
        BoxShadow(
          color: liftColor ?? accent, // 0 0 2rem -.6rem bloom
          blurRadius: 15.4,
          spreadRadius: -4.6,
        ),
      ];

  /// Small card resting shadow: `0 .8rem 2rem rgba(0,0,0,.22)`.
  static const List<BoxShadow> cardShadow = [
    BoxShadow(
      color: Color(0x38000000),
      offset: Offset(0, 6.1),
      blurRadius: 15.4,
    ),
  ];

  /// Sidebar: `1.2rem 0 3rem rgba(0,0,0,.32)`.
  static const List<BoxShadow> sidebarShadow = [
    BoxShadow(
      color: Color(0x52000000),
      offset: Offset(9.2, 0),
      blurRadius: 23,
    ),
  ];

  /// Bottombar: `0 -1.2rem 3rem rgba(0,0,0,.35)`.
  static const List<BoxShadow> bottombarShadow = [
    BoxShadow(
      color: Color(0x59000000),
      offset: Offset(0, -9.2),
      blurRadius: 23,
    ),
  ];

  /// Home feed lip: `0 -1.2rem 3rem rgba(0,0,0,.18)`.
  static const List<BoxShadow> feedLipShadow = [
    BoxShadow(
      color: Color(0x2E000000),
      offset: Offset(0, -9.2),
      blurRadius: 23,
    ),
  ];

  /// Hero CTA pill glow: `0 .4rem 1.8rem hsla(217,77%,54%,.45)`.
  static const List<BoxShadow> ctaGlow = [
    BoxShadow(
      color: Color(0x732F75E4),
      offset: Offset(0, 3.1),
      blurRadius: 13.8,
    ),
  ];

  /// Active nav pill outer glow: `0 .5rem 1.6rem hsla(tertiary,.16)`.
  /// (The inset ring half is drawn as a border — Flutter has no inset shadow.)
  static const List<BoxShadow> navPillGlow = [
    BoxShadow(
      color: Color(0x292F75E4),
      offset: Offset(0, 3.8),
      blurRadius: 12.3,
    ),
  ];

  /// Toast: `0 .8rem 2rem rgba(0,0,0,.55)`.
  static const List<BoxShadow> toastShadow = [
    BoxShadow(
      color: Color(0x8C000000),
      offset: Offset(0, 6.1),
      blurRadius: 15.4,
    ),
  ];

  // ---------------------------------------------------------------------------
  // Poster card geometry (SmallCard)
  // ---------------------------------------------------------------------------

  /// Card width in rails: 19rem.
  static const double cardWidth = 146;

  /// Container aspect ratio 152/296; artwork aspect 230/331.
  static const double cardAspect = 152 / 296;
  static const double cardArtAspect = 230 / 331;

  /// Container padding .65rem.
  static const double cardPadding = 5.0;

  /// Hover translate: 0 -.5rem.
  static const double cardHoverRise = 3.8;

  /// Hover border `hsla(217,77%,54%,.42)`; hover bg `hsla(220,10%,14%,.8)`.
  static const Color cardHoverBorder = Color(0x6B2F75E4);
  static const Color cardHoverBg = Color(0xCC202327);

  /// Focus ring: .25rem solid accent, offset .2rem.
  static const double focusRingWidth = 1.9;
  static const double focusRingOffset = 1.5;

  // ---------------------------------------------------------------------------
  // Ambient background (§1.11)
  // ---------------------------------------------------------------------------

  /// Top-right bloom: tertiary at 0.17 alpha.
  static const Color ambientBloomTopRight = Color(0x2B2F75E4);

  /// Bottom-left bloom: accent (#E5204C) at 8%.
  static const Color ambientBloomBottomLeft = Color(0x14E5204C);

  /// Vertical settle: darkDim → dark over 34rem.
  static const double ambientSettleExtent = 261; // 34rem

  // ---------------------------------------------------------------------------
  // Nav washes (§1.9)
  // ---------------------------------------------------------------------------

  static const Color navHoverWash = Color(0x1AFFFFFF); // white .10
  static const Color navPressWash = Color(0x29FFFFFF); // white .16
  static const Color navPillRing = Color(0x802F75E4); // hsla(tertiary,.5)
  static const Color navPillGradTop = Color(0x6B2F75E4); // .42
  static const Color navPillGradBottom = Color(0x332F75E4); // .2

  // ---------------------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------------------

  static const double emptyGlyphSize = 36.9; // 4.8rem
  static const Color emptyGlyphColor = Color(0x47FFFFFF); // white .28
  static const double emptyMinHeight = 184; // 24rem
}
