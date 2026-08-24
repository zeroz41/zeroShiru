import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'theme/tokens.dart';
import 'widgets/ambient_background.dart';
import 'widgets/hover_region.dart';

/// The navigation shell (design-map §1.12).
///
/// Breakpoint 769px: desktop = left rail (54px wide), mobile = bottom bar
/// (54px tall). Surfaces: `linear-gradient(panel-strong → shell)`, hairline
/// edge, pre-painted shadow. Pages render on top of [AmbientBackground].
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const destinations = [
    (path: '/home', icon: Icons.home_rounded, label: 'Home'),
    (path: '/search', icon: Icons.search_rounded, label: 'Search'),
    (path: '/downloads', icon: Icons.download_rounded, label: 'Downloads'),
    (path: '/settings', icon: Icons.settings_rounded, label: 'Settings'),
  ];

  int get _selectedIndex {
    final i = destinations.indexWhere((d) => location.startsWith(d.path));
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        MediaQuery.sizeOf(context).width >= ShiruTokens.desktopBreakpoint;
    final content = AmbientBackground(child: child);

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            _SideRail(selectedIndex: _selectedIndex),
            Expanded(child: content),
          ],
        ),
      );
    }
    return Scaffold(
      body: Column(
        children: [
          Expanded(child: content),
          _BottomBar(selectedIndex: _selectedIndex),
        ],
      ),
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({required this.selectedIndex});

  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: ShiruTokens.sidebarWidth,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ShiruTokens.surfacePanelStrong, ShiruTokens.surfaceShell],
        ),
        border: Border(right: BorderSide(color: ShiruTokens.surfaceBorder)),
        boxShadow: ShiruTokens.sidebarShadow,
      ),
      child: Column(
        children: [
          const SizedBox(height: ShiruTokens.space3),
          const _BrandMark(),
          const SizedBox(height: ShiruTokens.space4),
          for (var i = 0; i < AppShell.destinations.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: ShiruTokens.space1),
              child: _NavItem(
                destination: AppShell.destinations[i],
                active: i == selectedIndex,
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.selectedIndex});

  final int selectedIndex;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: ShiruTokens.sidebarWidth,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [ShiruTokens.surfacePanelStrong, ShiruTokens.surfaceShell],
        ),
        border: Border(top: BorderSide(color: ShiruTokens.surfaceBorder)),
        boxShadow: ShiruTokens.bottombarShadow,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < AppShell.destinations.length; i++)
            _NavItem(
              destination: AppShell.destinations[i],
              active: i == selectedIndex,
            ),
        ],
      ),
    );
  }
}

/// Brand mark placeholder: 5rem square, radius 1.35rem,
/// `linear-gradient(145deg, hsla(tertiary,.3), surface-highlight)`,
/// inset light ring + drop shadow.
class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: ShiruTokens.brandMarkSize,
      height: ShiruTokens.brandMarkSize,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBrand),
        gradient: const LinearGradient(
          begin: Alignment(-0.57, -1), // ~145deg
          end: Alignment(0.57, 1),
          colors: [
            Color(0x4D2F75E4), // hsla(tertiary,.3)
            ShiruTokens.surfaceHighlight,
          ],
        ),
        border: Border.all(color: const Color(0x26FFFFFF)), // white .15 ring
        boxShadow: const [
          BoxShadow(
            color: Color(0x6B000000), // 0 .8rem 2rem rgba(0,0,0,.42)
            offset: Offset(0, 6.1),
            blurRadius: 15.4,
          ),
        ],
      ),
      child: const Center(
        child: Text(
          'ゼ',
          style: TextStyle(
            fontSize: ShiruTokens.fontScale16,
            fontWeight: FontWeight.w900,
            color: ShiruTokens.accentVeryLight,
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.destination, required this.active});

  final ({String path, IconData icon, String label}) destination;
  final bool active;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.destination;
    return HoverRegion(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) {
        final iconColor = widget.active
            ? ShiruTokens.accentVeryLight
            : (hovered ? ShiruTokens.highlight : ShiruTokens.grayVeryDim);
        final labelColor = widget.active
            ? ShiruTokens.highlight
            : (hovered ? ShiruTokens.highlight : ShiruTokens.grayVeryDim);
        return Semantics(
          selected: widget.active,
          button: true,
          label: d.label,
          child: GestureDetector(
            onTap: () => context.go(d.path),
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: SizedBox(
              width: ShiruTokens.sidebarWidth - ShiruTokens.space2,
              height: ShiruTokens.navLinkHeight,
              child: Stack(
                children: [
                  // Active accent pill: gradient bg + inset-style ring +
                  // pre-painted glow, faded via opacity.
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: widget.active ? 1 : 0,
                      duration: ShiruTokens.motionQuick,
                      curve: ShiruTokens.easeSettle,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            ShiruTokens.radiusPanel,
                          ),
                          gradient: const LinearGradient(
                            begin: Alignment(-0.57, -1), // ~145deg
                            end: Alignment(0.57, 1),
                            colors: [
                              ShiruTokens.navPillGradTop,
                              ShiruTokens.navPillGradBottom,
                            ],
                          ),
                          border: Border.all(color: ShiruTokens.navPillRing),
                          boxShadow: ShiruTokens.navPillGlow,
                        ),
                      ),
                    ),
                  ),
                  // Hover / press wash.
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: _pressed || hovered ? 1 : 0,
                      duration: _pressed
                          ? ShiruTokens.motionPress
                          : ShiruTokens.motionQuick,
                      curve: _pressed
                          ? ShiruTokens.easePress
                          : ShiruTokens.easeSettle,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            ShiruTokens.radiusPanel,
                          ),
                          color: _pressed
                              ? ShiruTokens.navPressWash
                              : ShiruTokens.navHoverWash,
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AnimatedScale(
                          scale: _pressed ? 0.92 : (hovered ? 1.08 : 1.0),
                          duration: ShiruTokens.motionPress,
                          curve: ShiruTokens.easePress,
                          child: Icon(d.icon, size: 20, color: iconColor),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          d.label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: TextStyle(
                            fontFamily: ShiruTokens.fontFamily,
                            fontSize: ShiruTokens.fontSize12,
                            fontWeight: widget.active
                                ? FontWeight.w700
                                : FontWeight.w600,
                            color: labelColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
