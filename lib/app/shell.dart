import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/library/providers.dart';
import '../domain/models/tracking_account.dart';
import 'theme/tokens.dart';
import 'widgets/ambient_background.dart';
import 'widgets/empty_state.dart';
import 'widgets/hover_region.dart';
import 'widgets/page_motion.dart';
import 'widgets/soft_modal.dart';

/// The navigation shell (design-map §1.12).
///
/// Breakpoint 769px: desktop = user-controlled compact/labelled rail, mobile
/// = four primary destinations plus an overflow menu.
/// Surfaces: `linear-gradient(panel-strong → shell)`, hairline
/// edge, pre-painted shadow. Pages render on top of [AmbientBackground].
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  static const destinations = [
    (path: '/home', icon: Icons.home_rounded, label: 'Home'),
    (path: '/search', icon: Icons.search_rounded, label: 'Search'),
    (path: '/schedule', icon: Icons.calendar_month_rounded, label: 'Schedule'),
    (path: '/downloads', icon: Icons.download_rounded, label: 'Downloads'),
    (path: '/settings', icon: Icons.settings_rounded, label: 'Settings'),
  ];

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _railExpanded = false;

  int get _selectedIndex {
    final i = AppShell.destinations.indexWhere(
      (d) => widget.location.startsWith(d.path),
    );
    return i < 0 ? 0 : i;
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        MediaQuery.sizeOf(context).width >= ZeroTokens.desktopBreakpoint;
    final content = AmbientBackground(
      child: PageMotion(motionKey: widget.location, child: widget.child),
    );

    if (isDesktop) {
      return Scaffold(
        body: Stack(
          children: [
            // Keep the page at a stable width while the labelled rail opens.
            // Only the small navigation surface is laid out during the
            // animation, which avoids reflowing image-heavy home rails.
            Positioned.fill(
              left: ZeroTokens.sidebarWidth,
              child: RepaintBoundary(child: content),
            ),
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _SideRail(
                selectedIndex: _selectedIndex,
                expanded: _railExpanded,
                onToggle: () => setState(() => _railExpanded = !_railExpanded),
              ),
            ),
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
  const _SideRail({
    required this.selectedIndex,
    required this.expanded,
    required this.onToggle,
  });

  final int selectedIndex;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return RepaintBoundary(
      child: AnimatedContainer(
        key: const ValueKey('desktop-navigation-rail'),
        width: expanded
            ? ZeroTokens.sidebarExpandedWidth
            : ZeroTokens.sidebarWidth,
        duration: reduceMotion ? Duration.zero : ZeroTokens.motion,
        curve: ZeroTokens.easeSettle,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [ZeroTokens.surfacePanelStrong, ZeroTokens.surfaceShell],
          ),
          border: Border(right: BorderSide(color: ZeroTokens.surfaceBorder)),
          boxShadow: ZeroTokens.sidebarShadow,
        ),
        child: ClipRect(
          child: Column(
            children: [
              const SizedBox(height: ZeroTokens.space3),
              _RailHeader(expanded: expanded, onToggle: onToggle),
              const SizedBox(height: ZeroTokens.space4),
              for (var i = 0; i < AppShell.destinations.length - 1; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: ZeroTokens.space1),
                  child: _NavItem(
                    destination: AppShell.destinations[i],
                    active: i == selectedIndex,
                    expanded: true,
                    inline: expanded,
                    showLabel: expanded,
                  ),
                ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: ZeroTokens.space1),
                child: _NavItem.action(
                  icon: Icons.notifications_none_rounded,
                  label: 'Updates',
                  expanded: true,
                  inline: expanded,
                  showLabel: expanded,
                  onTap: () =>
                      _showShellPanel(context, const _NotificationPanel()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: ZeroTokens.space1),
                child: _NavItem(
                  destination: AppShell.destinations.last,
                  active: selectedIndex == AppShell.destinations.length - 1,
                  expanded: true,
                  inline: expanded,
                  showLabel: expanded,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: ZeroTokens.space3),
                child: _NavItem.action(
                  icon: Icons.account_circle_outlined,
                  label: 'Profile',
                  expanded: true,
                  inline: expanded,
                  showLabel: expanded,
                  onTap: () => _showShellPanel(context, const _ProfilePanel()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return SizedBox(
      height: ZeroTokens.brandMarkSize,
      child: AnimatedSwitcher(
        duration: reduceMotion ? Duration.zero : ZeroTokens.motionQuick,
        switchInCurve: ZeroTokens.easeSettle,
        switchOutCurve: ZeroTokens.easePress,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(-0.06, 0),
              end: Offset.zero,
            ).animate(animation),
            child: child,
          ),
        ),
        child: expanded
            ? Padding(
                key: const ValueKey('expanded-rail-header'),
                padding: const EdgeInsets.symmetric(
                  horizontal: ZeroTokens.space2,
                ),
                child: Row(
                  children: [
                    const _BrandMark(size: 36),
                    const SizedBox(width: ZeroTokens.space2),
                    const Expanded(
                      child: Text(
                        'Zero',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          color: ZeroTokens.highlight,
                          fontWeight: FontWeight.w800,
                          fontSize: ZeroTokens.fontScale16,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('desktop-menu-toggle'),
                      tooltip: 'Collapse navigation',
                      onPressed: onToggle,
                      icon: const Icon(Icons.menu_open_rounded),
                    ),
                  ],
                ),
              )
            : IconButton(
                key: const ValueKey('desktop-menu-toggle'),
                tooltip: 'Expand navigation',
                onPressed: onToggle,
                icon: const Icon(Icons.menu_rounded),
              ),
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
      height: ZeroTokens.sidebarWidth,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [ZeroTokens.surfacePanelStrong, ZeroTokens.surfaceShell],
        ),
        border: Border(top: BorderSide(color: ZeroTokens.surfaceBorder)),
        boxShadow: ZeroTokens.bottombarShadow,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < AppShell.destinations.length - 1; i++)
            Expanded(
              child: _NavItem(
                destination: AppShell.destinations[i],
                active: i == selectedIndex,
                expanded: true,
              ),
            ),
          Expanded(
            child: _MobileMoreMenu(
              active: selectedIndex == AppShell.destinations.length - 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _MobileMoreMenu extends StatelessWidget {
  const _MobileMoreMenu({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      useRootOverlay: true,
      animated: true,
      alignmentOffset: const Offset(0, -ZeroTokens.space2),
      menuChildren: [
        MenuItemButton(
          leadingIcon: const Icon(Icons.settings_rounded),
          onPressed: () => context.go('/settings'),
          child: const Text('Settings'),
        ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.notifications_none_rounded),
          onPressed: () => _showShellPanel(context, const _NotificationPanel()),
          child: const Text('Updates'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.account_circle_outlined),
          onPressed: () => _showShellPanel(context, const _ProfilePanel()),
          child: const Text('Profile'),
        ),
        const Divider(),
        MenuItemButton(
          leadingIcon: const Icon(Icons.info_outline_rounded),
          onPressed: () => _showShellPanel(context, const _AboutPanel()),
          child: const Text('About & shortcuts'),
        ),
      ],
      builder: (context, controller, child) => _NavItem.action(
        icon: controller.isOpen
            ? Icons.close_rounded
            : Icons.more_horiz_rounded,
        label: 'More',
        active: controller.isOpen || active,
        expanded: true,
        onTap: controller.isOpen ? controller.close : controller.open,
      ),
    );
  }
}

Future<void> _showShellPanel(BuildContext context, Widget panel) {
  return showSoftModal<void>(
    context: context,
    builder: (context) => SoftModal(maxWidth: 520, child: panel),
  );
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        DecoratedBox(
          decoration: const BoxDecoration(
            color: Color(0x297C3AED),
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(ZeroTokens.space2),
            child: Icon(icon, color: ZeroTokens.accentVeryLight),
          ),
        ),
        const SizedBox(width: ZeroTokens.space3),
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }
}

class _NotificationPanel extends StatelessWidget {
  const _NotificationPanel();

  @override
  Widget build(BuildContext context) {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PanelHeader(icon: Icons.notifications_none_rounded, title: 'Updates'),
        SizedBox(height: ZeroTokens.space3),
        EmptyState(
          icon: Icons.notifications_paused_outlined,
          message: 'You’re all caught up',
          detail: 'New episode and library activity will collect here without interrupting playback.',
        ),
      ],
    );
  }
}

class _ProfilePanel extends ConsumerWidget {
  const _ProfilePanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(trackingAccountsProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _PanelHeader(
          icon: Icons.account_circle_outlined,
          title: 'Local profile',
        ),
        const SizedBox(height: ZeroTokens.space4),
        ZeroAnimatedSwitcher(
          child: accounts.when(
            loading: () => const Padding(
              key: ValueKey('profile-loading'),
              padding: EdgeInsets.all(ZeroTokens.space5),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, _) => _AccountMessage(
              key: const ValueKey('profile-error'),
              icon: Icons.sync_problem_rounded,
              message: 'Tracking accounts could not be read from this device.',
              action: TextButton(
                onPressed: () => ref.invalidate(trackingAccountsProvider),
                child: const Text('Retry'),
              ),
            ),
            data: (items) => items.isEmpty
                ? const _AccountMessage(
                    key: ValueKey('profile-empty'),
                    icon: Icons.person_add_alt_1_rounded,
                    message:
                        'No AniList or MyAnimeList account is connected yet.',
                  )
                : Column(
                    key: const ValueKey('profile-accounts'),
                    children: [
                      for (final account in items)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: ZeroTokens.space2,
                          ),
                          child: _TrackingAccountRow(account: account),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: ZeroTokens.space5),
        FilledButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            context.go('/settings');
          },
          icon: const Icon(Icons.tune_rounded),
          label: const Text('Open device settings'),
        ),
      ],
    );
  }
}

class _AccountMessage extends StatelessWidget {
  const _AccountMessage({
    super.key,
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZeroTokens.surfacePanel,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        border: Border.all(color: ZeroTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space4),
        child: Row(
          children: [
            Icon(icon, color: ZeroTokens.textLight),
            const SizedBox(width: ZeroTokens.space3),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: ZeroTokens.textLight, height: 1.4),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class _TrackingAccountRow extends StatelessWidget {
  const _TrackingAccountRow({required this.account});

  final TrackingAccount account;

  @override
  Widget build(BuildContext context) {
    final (service, color) = switch (account.service) {
      TrackingAccountService.aniList => ('AniList', ZeroTokens.aniList),
      TrackingAccountService.myAnimeList => (
        'MyAnimeList',
        ZeroTokens.myAnimeList,
      ),
    };
    final (status, statusColor, statusIcon) = switch (account.health) {
      TrackingAccountHealth.connected => (
        'Connected',
        ZeroTokens.completed,
        Icons.check_circle_outline_rounded,
      ),
      TrackingAccountHealth.attention => (
        'Reconnect soon',
        ZeroTokens.warning,
        Icons.schedule_rounded,
      ),
      TrackingAccountHealth.expired => (
        'Reconnect required',
        ZeroTokens.errorVeryLight,
        Icons.error_outline_rounded,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZeroTokens.surfacePanel,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        border: Border.all(color: ZeroTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space3),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color,
              foregroundImage: account.avatarUrl == null
                  ? null
                  : NetworkImage(account.avatarUrl!),
              child: Text(
                service.characters.first,
                style: const TextStyle(
                  color: ZeroTokens.highlight,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: ZeroTokens.space3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    account.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(service, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(statusIcon, size: 17, color: statusColor),
            const SizedBox(width: ZeroTokens.space1),
            Text(
              status,
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: statusColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutPanel extends StatelessWidget {
  const _AboutPanel();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelHeader(
          icon: Icons.play_circle_outline_rounded,
          title: 'Zero',
        ),
        const SizedBox(height: ZeroTokens.space4),
        Text(
          'Flutter rewrite preview · Pure Dart playback and services',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: ZeroTokens.space5),
        Text(
          'Quick navigation',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: ZeroTokens.space2),
        const Wrap(
          spacing: ZeroTokens.space2,
          runSpacing: ZeroTokens.space2,
          children: [
            _Shortcut(label: 'Search', keys: '/'),
            _Shortcut(label: 'Back', keys: 'Esc'),
            _Shortcut(label: 'Activate', keys: 'Enter'),
            _Shortcut(label: 'Move focus', keys: 'Arrow keys'),
          ],
        ),
      ],
    );
  }
}

class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.label, required this.keys});

  final String label;
  final String keys;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZeroTokens.darkVeryLight,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        border: Border.all(color: ZeroTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ZeroTokens.space3,
          vertical: ZeroTokens.space2,
        ),
        child: Text('$label  ·  $keys'),
      ),
    );
  }
}

/// The compact Zero application mark.
class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = ZeroTokens.brandMarkSize});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBrand),
        color: const Color(0xFFF7F5FF),
        border: Border.all(color: const Color(0x4DC4B5FD)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x527C3AED),
            offset: Offset(0, 4),
            blurRadius: 12,
          ),
        ],
      ),
      child: Image.asset(
        'assets/images/zero-app-icon.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) => const Center(
          child: Icon(Icons.play_arrow_rounded, color: ZeroTokens.accent),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.destination,
    required this.active,
    this.expanded = false,
    this.inline = false,
    this.showLabel = true,
  }) : icon = null,
       label = null,
       onTap = null;

  const _NavItem.action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.expanded = false,
    this.inline = false,
    this.showLabel = true,
  }) : destination = null;

  final ({String path, IconData icon, String label})? destination;
  final IconData? icon;
  final String? label;
  final VoidCallback? onTap;
  final bool active;
  final bool expanded;
  final bool inline;
  final bool showLabel;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final d = widget.destination;
    final icon = d?.icon ?? widget.icon!;
    final label = d?.label ?? widget.label!;
    final onTap = widget.onTap ?? () => context.go(d!.path);
    final item = HoverRegion(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) {
        final iconColor = widget.active
            ? ZeroTokens.accentVeryLight
            : (hovered ? ZeroTokens.highlight : ZeroTokens.textMuted);
        final labelColor = widget.active
            ? ZeroTokens.highlight
            : (hovered ? ZeroTokens.highlight : ZeroTokens.textMuted);
        return Semantics(
          selected: widget.active,
          button: true,
          label: label,
          child: GestureDetector(
            onTap: onTap,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: SizedBox(
              width: widget.expanded
                  ? double.infinity
                  : ZeroTokens.sidebarWidth - ZeroTokens.space3,
              height: ZeroTokens.navLinkHeight,
              child: Stack(
                children: [
                  // Active accent pill: gradient bg + inset-style ring +
                  // pre-painted glow, faded via opacity.
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: widget.active ? 1 : 0,
                      duration: ZeroTokens.motionQuick,
                      curve: ZeroTokens.easeSettle,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            ZeroTokens.radiusPanel,
                          ),
                          gradient: const LinearGradient(
                            begin: Alignment(-0.57, -1), // ~145deg
                            end: Alignment(0.57, 1),
                            colors: [
                              ZeroTokens.navPillGradTop,
                              ZeroTokens.navPillGradBottom,
                            ],
                          ),
                          border: Border.all(color: ZeroTokens.navPillRing),
                          boxShadow: ZeroTokens.navPillGlow,
                        ),
                      ),
                    ),
                  ),
                  // Hover / press wash.
                  Positioned.fill(
                    child: AnimatedOpacity(
                      opacity: _pressed || hovered ? 1 : 0,
                      duration: _pressed
                          ? ZeroTokens.motionPress
                          : ZeroTokens.motionQuick,
                      curve: _pressed
                          ? ZeroTokens.easePress
                          : ZeroTokens.easeSettle,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(
                            ZeroTokens.radiusPanel,
                          ),
                          color: _pressed
                              ? ZeroTokens.navPressWash
                              : ZeroTokens.navHoverWash,
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.inline ? ZeroTokens.space4 : 0,
                      ),
                      child: AnimatedSwitcher(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : ZeroTokens.motionQuick,
                        switchInCurve: ZeroTokens.easeSettle,
                        switchOutCurve: ZeroTokens.easePress,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(-0.08, 0),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: widget.inline
                            ? Row(
                                key: ValueKey('nav-inline-$label'),
                                children: [
                                  AnimatedScale(
                                    scale: _pressed
                                        ? 0.92
                                        : (hovered ? 1.08 : 1.0),
                                    duration: ZeroTokens.motionPress,
                                    curve: ZeroTokens.easePress,
                                    child: Icon(
                                      icon,
                                      size: 20,
                                      color: iconColor,
                                    ),
                                  ),
                                  const SizedBox(width: ZeroTokens.space3),
                                  Expanded(
                                    child: Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.fade,
                                      softWrap: false,
                                      style: TextStyle(
                                        fontFamily: ZeroTokens.fontFamily,
                                        fontSize: ZeroTokens.fontScale14,
                                        fontWeight: widget.active
                                            ? FontWeight.w700
                                            : FontWeight.w600,
                                        color: labelColor,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Center(
                                key: ValueKey('nav-compact-$label'),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    AnimatedScale(
                                      scale: _pressed
                                          ? 0.92
                                          : (hovered ? 1.08 : 1.0),
                                      duration: ZeroTokens.motionPress,
                                      curve: ZeroTokens.easePress,
                                      child: Icon(
                                        icon,
                                        size: 20,
                                        color: iconColor,
                                      ),
                                    ),
                                    if (widget.showLabel) ...[
                                      const SizedBox(height: 2),
                                      FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Text(
                                          label,
                                          maxLines: 1,
                                          style: TextStyle(
                                            fontFamily: ZeroTokens.fontFamily,
                                            fontSize: ZeroTokens.fontSize12,
                                            fontWeight: widget.active
                                                ? FontWeight.w700
                                                : FontWeight.w600,
                                            color: labelColor,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    return widget.showLabel
        ? item
        : Tooltip(message: label, preferBelow: false, child: item);
  }
}
