import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'hover_region.dart';

/// A titled horizontal rail (design-map §1.10, HomeSection).
///
/// Header: accent gradient tab + 18.4px w700 title in the highlight color
/// (hover → tertiary-very-light). Scroller: hidden scrollbar, drag-to-scroll
/// (mouse included), right-edge fade, and desktop chevrons that page one
/// viewport per click with wrap-around.
class TitledRail extends StatefulWidget {
  const TitledRail({
    super.key,
    required this.title,
    required this.children,
    this.onTitleTap,
    this.itemSpacing = ZeroTokens.space3,
    this.minHeight = 192, // 25rem
  });

  final String title;
  final List<Widget> children;

  /// Old app: rail title navigates to Search pre-filled with the rail query.
  final VoidCallback? onTitleTap;

  final double itemSpacing;
  final double minHeight;

  @override
  State<TitledRail> createState() => _TitledRailState();
}

class _TitledRailState extends State<TitledRail> {
  final ScrollController _controller = ScrollController();
  bool _paging = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Pages by one viewport width, smooth, wrapping at the ends.
  Future<void> _page(int direction) async {
    if (_paging || !_controller.hasClients) return;
    final position = _controller.position;
    final viewport = position.viewportDimension;
    double target = position.pixels + direction * viewport;
    if (direction > 0 && position.pixels >= position.maxScrollExtent - 1) {
      target = 0; // wrap to start
    } else if (direction < 0 && position.pixels <= 1) {
      target = position.maxScrollExtent; // wrap to end
    } else {
      target = target.clamp(0, position.maxScrollExtent);
    }
    _paging = true;
    await _controller.animateTo(
      target,
      duration: ZeroTokens.motionPanel,
      curve: ZeroTokens.easeSettle,
    );
    _paging = false;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: ZeroTokens.space3),
          child: _RailHeader(title: widget.title, onTap: widget.onTitleTap),
        ),
        HoverRegion(
          builder: (context, hovered) {
            return ConstrainedBox(
              constraints: BoxConstraints(minHeight: widget.minHeight),
              child: Stack(
                children: [
                  ScrollConfiguration(
                    behavior: const _RailScrollBehavior(),
                    child: SingleChildScrollView(
                      controller: _controller,
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: Padding(
                        // Poster cards rise on hover. Reserve that paint space
                        // so the scroll viewport does not cut off their top
                        // accent ring.
                        padding: const EdgeInsets.only(
                          top: ZeroTokens.cardHoverRise + 1,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (
                              var i = 0;
                              i < widget.children.length;
                              i++
                            ) ...[
                              if (i > 0) SizedBox(width: widget.itemSpacing),
                              widget.children[i],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Right edge fade: 8rem, dark -> transparent.
                  const Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: SizedBox(
                        width: 61, // 8rem
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerRight,
                              end: Alignment.centerLeft,
                              colors: [ZeroTokens.dark, Color(0x0017191C)],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Desktop chevrons — appear only under a hovering pointer.
                  Positioned(
                    left: ZeroTokens.space1,
                    top: 0,
                    bottom: 0,
                    child: _RailChevron(
                      icon: Icons.chevron_left_rounded,
                      visible: hovered,
                      onTap: () => _page(-1),
                    ),
                  ),
                  Positioned(
                    right: ZeroTokens.space1,
                    top: 0,
                    bottom: 0,
                    child: _RailChevron(
                      icon: Icons.chevron_right_rounded,
                      visible: hovered,
                      onTap: () => _page(1),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.title, this.onTap});

  final String title;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return HoverRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      builder: (context, hovered) {
        return GestureDetector(
          onTap: onTap,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Accent tab: .45rem x 1.05em, radius pill, vertical
              // gradient light -> base, margin-right 1rem.
              Container(
                width: 3.5,
                height: ZeroTokens.fontScale24 * 1.05 * 0.8,
                margin: const EdgeInsets.only(right: ZeroTokens.remPx),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [ZeroTokens.accentLight, ZeroTokens.accent],
                  ),
                ),
              ),
              Text(
                title,
                style: TextStyle(
                  fontFamily: ZeroTokens.fontFamily,
                  fontSize: ZeroTokens.fontScale24,
                  fontWeight: FontWeight.w700,
                  color: hovered
                      ? ZeroTokens.accentVeryLight
                      : ZeroTokens.highlight,
                ),
              ),
              if (onTap != null) ...[
                const SizedBox(width: ZeroTokens.space1),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: hovered
                      ? ZeroTokens.accentVeryLight
                      : ZeroTokens.textMuted,
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _RailChevron extends StatelessWidget {
  const _RailChevron({
    required this.icon,
    required this.visible,
    required this.onTap,
  });

  final IconData icon;
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: ZeroTokens.motion,
        curve: ZeroTokens.easeSettle,
        child: IgnorePointer(
          ignoring: !visible,
          child: HoverRegion(
            cursor: SystemMouseCursors.click,
            builder: (context, hovered) {
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  width: ZeroTokens.navButtonSize + 4,
                  height: ZeroTokens.navButtonSize + 4,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hovered
                        ? ZeroTokens.darkVeryLight
                        : ZeroTokens.surfaceShell,
                    border: Border.all(color: ZeroTokens.surfaceBorder),
                  ),
                  child: Icon(
                    icon,
                    size: 18,
                    color: hovered ? ZeroTokens.highlight : ZeroTokens.text,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// No scrollbar; drag-to-scroll with mouse and touch alike.
class _RailScrollBehavior extends ScrollBehavior {
  const _RailScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}
