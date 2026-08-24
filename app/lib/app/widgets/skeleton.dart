import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Loading skeleton with the sweep shimmer (design-map §1.13):
/// 1s infinite cubic-bezier(.4,0,.2,1), highlight rgba(255,255,255,.06).
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.borderRadius = ShiruTokens.radiusPanel,
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
    duration: ShiruTokens.skeletonSweep,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: DecoratedBox(
          decoration: const BoxDecoration(color: ShiruTokens.surfacePanel),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              final t = ShiruTokens.skeletonCurve.transform(_controller.value);
              // Sweep a highlight band across: -1 (off left) -> 2 (off
              // right) in gradient alignment space.
              final x = -1.0 + 3.0 * t;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(x - 1, 0),
                    end: Alignment(x + 1, 0),
                    colors: const [
                      Color(0x00FFFFFF),
                      ShiruTokens.skeletonHighlight,
                      Color(0x00FFFFFF),
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
  const PosterSkeleton({super.key, this.width = ShiruTokens.cardWidth});

  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: ShiruTokens.cardAspect,
        child: const Skeleton(borderRadius: ShiruTokens.radiusCard),
      ),
    );
  }
}
