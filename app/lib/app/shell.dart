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
        MediaQuery.sizeOf(context).width >= ShiruTokens.desktopBreakpoint;
    final content = AmbientBackground(
      child: PageMotion(motionKey: widget.location, child: widget.child),
    );

    if (isDesktop) {
      return Scaffold(
        body: Row(
          children: [
            _SideRail(
              selectedIndex: _selectedIndex,
              expanded: _railExpanded,
              onToggle: () => setState(() => _railExpanded = !_railExpanded),
            ),
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
    return AnimatedContainer(
      key: const ValueKey('desktop-navigation-rail'),
      width: expanded
          ? ShiruTokens.sidebarExpandedWidth
          : ShiruTokens.sidebarWidth,
      duration: reduceMotion ? Duration.zero : ShiruTokens.motionPanel,
      curve: ShiruTokens.easeSettle,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ShiruTokens.surfacePanelStrong, ShiruTokens.surfaceShell],
        ),
        border: Border(right: BorderSide(color: ShiruTokens.surfaceBorder)),
        boxShadow: ShiruTokens.sidebarShadow,
      ),
      child: ClipRect(
        child: Column(
          children: [
            const SizedBox(height: ShiruTokens.space3),
            _RailHeader(expanded: expanded, onToggle: onToggle),
            const SizedBox(height: ShiruTokens.space4),
            for (var i = 0; i < AppShell.destinations.length - 1; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: ShiruTokens.space1),
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
              padding: const EdgeInsets.only(bottom: ShiruTokens.space1),
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
              padding: const EdgeInsets.only(bottom: ShiruTokens.space1),
              child: _NavItem(
                destination: AppShell.destinations.last,
                active: selectedIndex == AppShell.destinations.length - 1,
                expanded: true,
                inline: expanded,
                showLabel: expanded,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: ShiruTokens.space3),
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
      height: ShiruTokens.brandMarkSize,
      child: AnimatedSwitcher(
        duration: reduceMotion ? Duration.zero : ShiruTokens.motion,
        switchInCurve: ShiruTokens.easeSettle,
        switchOutCurve: ShiruTokens.easePress,
        child: expanded
            ? Padding(
                key: const ValueKey('expanded-rail-header'),
                padding: const EdgeInsets.symmetric(
                  horizontal: ShiruTokens.space2,
                ),
                child: Row(
                  children: [
                    const _BrandMark(size: 36),
                    const SizedBox(width: ShiruTokens.space2),
                    const Expanded(
                      child: Text(
                        'zeroShiru',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          color: ShiruTokens.highlight,
                          fontWeight: FontWeight.w800,
                          fontSize: ShiruTokens.fontScale16,
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
      alignmentOffset: const Offset(0, -ShiruTokens.space2),
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
            color: Color(0x292F75E4),
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(ShiruTokens.space2),
            child: Icon(icon, color: ShiruTokens.accentVeryLight),
          ),
        ),
        const SizedBox(width: ShiruTokens.space3),
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
        SizedBox(height: ShiruTokens.space3),
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
        const SizedBox(height: ShiruTokens.space4),
        ShiruAnimatedSwitcher(
          child: accounts.when(
            loading: () => const Padding(
              key: ValueKey('profile-loading'),
              padding: EdgeInsets.all(ShiruTokens.space5),
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
                            bottom: ShiruTokens.space2,
                          ),
                          child: _TrackingAccountRow(account: account),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: ShiruTokens.space5),
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
        color: ShiruTokens.surfacePanel,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
        border: Border.all(color: ShiruTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space4),
        child: Row(
          children: [
            Icon(icon, color: ShiruTokens.textLight),
            const SizedBox(width: ShiruTokens.space3),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: ShiruTokens.textLight, height: 1.4),
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
      TrackingAccountService.aniList => ('AniList', ShiruTokens.aniList),
      TrackingAccountService.myAnimeList => (
        'MyAnimeList',
        ShiruTokens.myAnimeList,
      ),
    };
    final (status, statusColor, statusIcon) = switch (account.health) {
      TrackingAccountHealth.connected => (
        'Connected',
        ShiruTokens.completed,
        Icons.check_circle_outline_rounded,
      ),
      TrackingAccountHealth.attention => (
        'Reconnect soon',
        ShiruTokens.warning,
        Icons.schedule_rounded,
      ),
      TrackingAccountHealth.expired => (
        'Reconnect required',
        ShiruTokens.errorVeryLight,
        Icons.error_outline_rounded,
      ),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShiruTokens.surfacePanel,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
        border: Border.all(color: ShiruTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space3),
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
                  color: ShiruTokens.highlight,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: ShiruTokens.space3),
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
            const SizedBox(width: ShiruTokens.space1),
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
          title: 'zeroShiru',
        ),
        const SizedBox(height: ShiruTokens.space4),
        Text(
          'Flutter rewrite preview · Pure Dart playback and services',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        const SizedBox(height: ShiruTokens.space5),
        Text(
          'Quick navigation',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: ShiruTokens.space2),
        const Wrap(
          spacing: ShiruTokens.space2,
          runSpacing: ShiruTokens.space2,
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
        color: ShiruTokens.darkVeryLight,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusBase),
        border: Border.all(color: ShiruTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.space3,
          vertical: ShiruTokens.space2,
        ),
        child: Text('$label  ·  $keys'),
      ),
    );
  }
}

/// The established zeroShiru mark, seated on the current shell surface.
class _BrandMark extends StatelessWidget {
  const _BrandMark({this.size = ShiruTokens.brandMarkSize});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
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
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Image.asset(
          'assets/images/zeroshiru-mark.png',
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
          errorBuilder: (_, _, _) => const Center(
            child: Icon(
              Icons.play_arrow_rounded,
              color: ShiruTokens.accentVeryLight,
            ),
          ),
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
            ? ShiruTokens.accentVeryLight
            : (hovered ? ShiruTokens.highlight : ShiruTokens.textMuted);
        final labelColor = widget.active
            ? ShiruTokens.highlight
            : (hovered ? ShiruTokens.highlight : ShiruTokens.textMuted);
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
                  : ShiruTokens.sidebarWidth - ShiruTokens.space3,
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
                  Positioned.fill(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: widget.inline ? ShiruTokens.space4 : 0,
                      ),
                      child: widget.inline
                          ? Row(
                              children: [
                                AnimatedScale(
                                  scale: _pressed
                                      ? 0.92
                                      : (hovered ? 1.08 : 1.0),
                                  duration: ShiruTokens.motionPress,
                                  curve: ShiruTokens.easePress,
                                  child: Icon(icon, size: 20, color: iconColor),
                                ),
                                const SizedBox(width: ShiruTokens.space3),
                                Expanded(
                                  child: Text(
                                    label,
                                    maxLines: 1,
                                    overflow: TextOverflow.fade,
                                    softWrap: false,
                                    style: TextStyle(
                                      fontFamily: ShiruTokens.fontFamily,
                                      fontSize: ShiruTokens.fontScale14,
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
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedScale(
                                    scale: _pressed
                                        ? 0.92
                                        : (hovered ? 1.08 : 1.0),
                                    duration: ShiruTokens.motionPress,
                                    curve: ShiruTokens.easePress,
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
                                          fontFamily: ShiruTokens.fontFamily,
                                          fontSize: ShiruTokens.fontSize12,
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
