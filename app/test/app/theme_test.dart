import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/app/theme/tokens.dart';

void main() {
  group('ShiruTokens', () {
    test('the two accents are distinct and correct', () {
      // Seekbar-only accent vs the real UI accent.
      expect(ShiruTokens.seekbarAccent, const Color(0xFFE5204C));
      expect(ShiruTokens.accent, const Color(0xFF2F75E4));
      expect(ShiruTokens.seekbarAccent, isNot(ShiruTokens.accent));
    });

    test('accent ramp and surfaces match the design map', () {
      expect(ShiruTokens.accentLight, const Color(0xFF5D93EA));
      expect(ShiruTokens.accentVeryLight, const Color(0xFFA0C0F3));
      expect(ShiruTokens.accentDim, const Color(0xFF123F87));
      expect(ShiruTokens.dark, const Color(0xFF17191C));
      expect(ShiruTokens.darkLight, const Color(0xFF202327));
      expect(ShiruTokens.darkVeryLight, const Color(0xFF25272D));
      expect(ShiruTokens.darkDim, const Color(0xFF121416));
      expect(ShiruTokens.darkVeryDim, const Color(0xFF090A0B));
      expect(ShiruTokens.grayLight, const Color(0xFF40464F));
      expect(ShiruTokens.primary, const Color(0xFF1A90FF));
      expect(ShiruTokens.octonary, const Color(0xFFFF6B35));
    });

    test('composite surfaces carry the right alphas', () {
      expect(ShiruTokens.surfaceShell.a, closeTo(0.97, 0.005));
      expect(ShiruTokens.surfacePanel.a, closeTo(0.72, 0.005));
      expect(ShiruTokens.surfacePanelStrong.a, closeTo(0.92, 0.005));
      expect(ShiruTokens.surfaceBorder.a, closeTo(0.11, 0.005));
      expect(ShiruTokens.surfaceHighlight.a, closeTo(0.055, 0.005));
    });

    test('text-on-dark opacities', () {
      expect(ShiruTokens.text.a, closeTo(0.80, 0.005));
      expect(ShiruTokens.textLight.a, closeTo(0.65, 0.005));
      expect(ShiruTokens.textMuted.a, closeTo(0.60, 0.005));
    });

    test('rem conversion is 7.68px per rem', () {
      expect(ShiruTokens.remPx, 7.68);
      expect(ShiruTokens.rem(2.4), closeTo(18.4, 0.05)); // font-scale-24
      expect(ShiruTokens.rem(19), closeTo(146, 0.5)); // card width
      expect(ShiruTokens.rem(7), closeTo(54, 0.5)); // sidebar
    });

    test('radii ladder', () {
      expect(ShiruTokens.radiusBase, 4.6);
      expect(ShiruTokens.radiusPosterArt, 6.9);
      expect(ShiruTokens.radiusPanel, 7.7);
      expect(ShiruTokens.radiusCard, 9.6);
      expect(ShiruTokens.radiusPill, greaterThan(100));
    });

    test('five motion durations and the two curves', () {
      expect(ShiruTokens.motionPress, const Duration(milliseconds: 90));
      expect(ShiruTokens.motionQuick, const Duration(milliseconds: 120));
      expect(ShiruTokens.motion, const Duration(milliseconds: 160));
      expect(ShiruTokens.motionPanel, const Duration(milliseconds: 240));
      expect(
        ShiruTokens.motionPageFade,
        const Duration(milliseconds: 180),
      );

      const settle = ShiruTokens.easeSettle as Cubic;
      expect(settle.a, 0.16);
      expect(settle.b, 0.84);
      expect(settle.c, 0.34);
      expect(settle.d, 1);

      const press = ShiruTokens.easePress as Cubic;
      expect(press.a, 0.2);
      expect(press.b, 0);
      expect(press.c, 0);
      expect(press.d, 1);
    });

    test('lift shadow blooms with the per-poster color', () {
      final tinted = ShiruTokens.liftShadow(const Color(0xFF00FF00));
      expect(tinted.last.color, const Color(0xFF00FF00));
      final fallback = ShiruTokens.liftShadow();
      expect(fallback.last.color, ShiruTokens.accent);
    });
  });

  group('buildShiruTheme', () {
    test('builds the dark theme from the tokens', () {
      final theme = buildShiruTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, ShiruTokens.dark);
      expect(theme.colorScheme.primary, ShiruTokens.accent);
      expect(theme.textTheme.bodyLarge?.fontFamily, 'Nunito');
      expect(
        theme.textTheme.headlineMedium?.fontSize,
        ShiruTokens.fontScale24,
      );
      expect(
        theme.textTheme.headlineMedium?.fontWeight,
        FontWeight.w700,
      );
      expect(
        theme.textTheme.displayMedium?.fontWeight,
        FontWeight.w900,
      );
      expect(theme.dialogTheme.backgroundColor, ShiruTokens.darkVeryDim);
    });
  });
}
