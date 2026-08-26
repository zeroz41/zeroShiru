import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/app/theme/tokens.dart';

void main() {
  group('ZeroTokens', () {
    test('the two accents are distinct and correct', () {
      // Seekbar-only accent vs the real UI accent.
      expect(ZeroTokens.seekbarAccent, const Color(0xFFE5204C));
      expect(ZeroTokens.accent, const Color(0xFF7C3AED));
      expect(ZeroTokens.seekbarAccent, isNot(ZeroTokens.accent));
    });

    test('accent ramp and surfaces match the design map', () {
      expect(ZeroTokens.accentLight, const Color(0xFF9F67FF));
      expect(ZeroTokens.accentVeryLight, const Color(0xFFC4B5FD));
      expect(ZeroTokens.accentDim, const Color(0xFF4C1D95));
      expect(ZeroTokens.dark, const Color(0xFF17191C));
      expect(ZeroTokens.darkLight, const Color(0xFF202327));
      expect(ZeroTokens.darkVeryLight, const Color(0xFF25272D));
      expect(ZeroTokens.darkDim, const Color(0xFF121416));
      expect(ZeroTokens.darkVeryDim, const Color(0xFF090A0B));
      expect(ZeroTokens.grayLight, const Color(0xFF40464F));
      expect(ZeroTokens.primary, ZeroTokens.accent);
      expect(ZeroTokens.octonary, const Color(0xFFFF6B35));
    });

    test('composite surfaces carry the right alphas', () {
      expect(ZeroTokens.surfaceShell.a, closeTo(0.97, 0.005));
      expect(ZeroTokens.surfacePanel.a, closeTo(0.72, 0.005));
      expect(ZeroTokens.surfacePanelStrong.a, closeTo(0.92, 0.005));
      expect(ZeroTokens.surfaceBorder.a, closeTo(0.11, 0.005));
      expect(ZeroTokens.surfaceHighlight.a, closeTo(0.055, 0.005));
    });

    test('text-on-dark opacities', () {
      expect(ZeroTokens.text.a, closeTo(0.80, 0.005));
      expect(ZeroTokens.textLight.a, closeTo(0.65, 0.005));
      expect(ZeroTokens.textMuted.a, closeTo(0.60, 0.005));
    });

    test('rem conversion is 7.68px per rem', () {
      expect(ZeroTokens.remPx, 7.68);
      expect(ZeroTokens.rem(2.4), closeTo(18.4, 0.05)); // font-scale-24
      expect(ZeroTokens.rem(19), closeTo(146, 0.5)); // card width
      expect(ZeroTokens.rem(7), closeTo(54, 0.5)); // sidebar
    });

    test('radii ladder', () {
      expect(ZeroTokens.radiusBase, 4.6);
      expect(ZeroTokens.radiusPosterArt, 6.9);
      expect(ZeroTokens.radiusPanel, 7.7);
      expect(ZeroTokens.radiusCard, 9.6);
      expect(ZeroTokens.radiusPill, greaterThan(100));
    });

    test('five motion durations and the two curves', () {
      expect(ZeroTokens.motionPress, const Duration(milliseconds: 90));
      expect(ZeroTokens.motionQuick, const Duration(milliseconds: 120));
      expect(ZeroTokens.motion, const Duration(milliseconds: 160));
      expect(ZeroTokens.motionPanel, const Duration(milliseconds: 240));
      expect(ZeroTokens.motionPageFade, const Duration(milliseconds: 180));

      const settle = ZeroTokens.easeSettle as Cubic;
      expect(settle.a, 0.16);
      expect(settle.b, 0.84);
      expect(settle.c, 0.34);
      expect(settle.d, 1);

      const press = ZeroTokens.easePress as Cubic;
      expect(press.a, 0.2);
      expect(press.b, 0);
      expect(press.c, 0);
      expect(press.d, 1);
    });

    test('lift shadow blooms with the per-poster color', () {
      final tinted = ZeroTokens.liftShadow(const Color(0xFF00FF00));
      expect(tinted.last.color, const Color(0xFF00FF00));
      final fallback = ZeroTokens.liftShadow();
      expect(fallback.last.color, ZeroTokens.accent);
    });
  });

  group('buildZeroTheme', () {
    test('builds the dark theme from the tokens', () {
      final theme = buildZeroTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, ZeroTokens.dark);
      expect(theme.colorScheme.primary, ZeroTokens.accent);
      expect(theme.textTheme.bodyLarge?.fontFamily, 'Nunito');
      expect(theme.textTheme.headlineMedium?.fontSize, ZeroTokens.fontScale24);
      expect(theme.textTheme.headlineMedium?.fontWeight, FontWeight.w700);
      expect(theme.textTheme.displayMedium?.fontWeight, FontWeight.w900);
      expect(theme.dialogTheme.backgroundColor, ZeroTokens.darkVeryDim);
    });
  });
}
