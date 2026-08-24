import 'package:flutter/widgets.dart';

import '../theme/tokens.dart';

/// The app-wide ambient page background (design-map §1.11).
///
/// Painted once and never animated:
///  1. top-right tertiary bloom  — `radial-gradient(110rem 55rem at 88% -12%,
///     hsla(217,77%,54%,.17), transparent 62%)`
///  2. bottom-left accent bloom  — `radial-gradient(80rem 55rem at 15% 112%,
///     accent 8%, transparent 68%)`
///  3. vertical settle           — `linear-gradient(180deg, #121416 0%,
///     #17191C 34rem)`
///
/// Pages are transparent so this wrapper shows through.
class AmbientBackground extends StatelessWidget {
  const AmbientBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: const _AmbientDecoration(),
        child: child ?? const SizedBox.expand(),
      ),
    );
  }
}

class _AmbientDecoration extends Decoration {
  const _AmbientDecoration();

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) => _AmbientPainter();
}

class _AmbientPainter extends BoxPainter {
  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size ?? Size.zero;
    if (size.isEmpty) return;
    final rect = offset & size;
    canvas.save();
    canvas.clipRect(rect);

    // 3. Vertical settle: darkDim -> dark over 34rem, then flat dark.
    final settleExtent = ShiruTokens.ambientSettleExtent.clamp(
      1.0,
      size.height,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [ShiruTokens.darkDim, ShiruTokens.dark],
          stops: [0, settleExtent / size.height],
        ).createShader(rect),
    );

    // 1. Top-right tertiary bloom: 110rem x 55rem at (88%, -12%), fade to
    // transparent at 62%.
    _bloom(
      canvas,
      rect,
      center: Offset(
        rect.left + size.width * 0.88,
        rect.top - size.height * 0.12,
      ),
      radiusX: ShiruTokens.rem(110),
      radiusY: ShiruTokens.rem(55),
      color: ShiruTokens.ambientBloomTopRight,
      fadeStop: 0.62,
    );

    // 2. Bottom-left accent bloom: 80rem x 55rem at (15%, 112%), fade at 68%.
    _bloom(
      canvas,
      rect,
      center: Offset(
        rect.left + size.width * 0.15,
        rect.top + size.height * 1.12,
      ),
      radiusX: ShiruTokens.rem(80),
      radiusY: ShiruTokens.rem(55),
      color: ShiruTokens.ambientBloomBottomLeft,
      fadeStop: 0.68,
    );

    canvas.restore();
  }

  /// Draws one elliptical bloom by scaling a circular radial gradient.
  void _bloom(
    Canvas canvas,
    Rect rect, {
    required Offset center,
    required double radiusX,
    required double radiusY,
    required Color color,
    required double fadeStop,
  }) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1, radiusY / radiusX);
    final gradientRect = Rect.fromCircle(center: Offset.zero, radius: radiusX);
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset.zero,
        width: radiusX * 2,
        height: radiusX * 2,
      ),
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: [0, fadeStop],
        ).createShader(gradientRect),
    );
    canvas.restore();
  }
}
