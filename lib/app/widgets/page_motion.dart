import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Replays the app-wide page entrance without mounting a second copy of the
/// routed subtree.
///
/// Keeping one child is important for the indexed router shell: Home and
/// Search retain scroll/image state while navigation still feels responsive.
/// Reduced-motion preferences skip the transition entirely.
class PageMotion extends StatefulWidget {
  const PageMotion({super.key, required this.motionKey, required this.child});

  final Object motionKey;
  final Widget child;

  @override
  State<PageMotion> createState() => _PageMotionState();
}

class _PageMotionState extends State<PageMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ZeroTokens.motionPageFade,
    value: 1,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  ).drive(Tween(begin: 0.4, end: 1));
  late final Animation<Offset> _offset = CurvedAnimation(
    parent: _controller,
    curve: ZeroTokens.easeSettle,
  ).drive(Tween(begin: const Offset(0, 0.008), end: Offset.zero));

  @override
  void didUpdateWidget(PageMotion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.motionKey != widget.motionKey) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _offset, child: widget.child),
    );
  }
}

/// Standard fade/settle transition for small state changes. The caller gives
/// each state a key; this widget centralizes timing and reduced-motion support.
class ZeroAnimatedSwitcher extends StatelessWidget {
  const ZeroAnimatedSwitcher({
    super.key,
    required this.child,
    this.duration = ZeroTokens.motionPanel,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : duration,
      reverseDuration: reduceMotion ? Duration.zero : ZeroTokens.motion,
      switchInCurve: ZeroTokens.easeSettle,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: alignment,
        children: [...previousChildren, ?currentChild],
      ),
      transitionBuilder: (child, animation) {
        final offset = Tween(
          begin: const Offset(0, 0.018),
          end: Offset.zero,
        ).animate(animation);
        return FadeTransition(
          opacity: animation,
          child: SlideTransition(position: offset, child: child),
        );
      },
      child: child,
    );
  }
}
