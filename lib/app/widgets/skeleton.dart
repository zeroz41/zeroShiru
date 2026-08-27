import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/tokens.dart';

/// Loading skeleton with the sweep shimmer (design-map §1.13):
/// 1s infinite cubic-bezier(.4,0,.2,1), highlight rgba(255,255,255,.06).
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.borderRadius = ZeroTokens.radiusPanel,
  });

  final double? width;
  final double? height;
  final double borderRadius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ZeroTokens.skeletonSweep,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: DecoratedBox(
          decoration: BoxDecoration(color: colors.panel),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = ZeroTokens.skeletonCurve.transform(_controller.value);
              // Sweep a highlight band across: -1 (off left) -> 2 (off
              // right) in gradient alignment space.
              final x = -1.0 + 3.0 * t;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(x - 1, 0),
                    end: Alignment(x + 1, 0),
                    colors: [
                      colors.skeletonHighlight.withValues(alpha: 0),
                      colors.skeletonHighlight,
                      colors.skeletonHighlight.withValues(alpha: 0),
                    ],
                  ),
                ),
                child: const SizedBox.expand(),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A poster-shaped skeleton matching [PosterCard] geometry, for rails.
class PosterSkeleton extends StatelessWidget {
  const PosterSkeleton({super.key, this.width = ZeroTokens.cardWidth});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: ZeroTokens.cardAspect,
        child: const Skeleton(borderRadius: ZeroTokens.radiusCard),
      ),
    );
  }
}
