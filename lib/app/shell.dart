import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/library/providers.dart';
import '../domain/models/tracking_account.dart';
import 'theme/palette.dart';
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
    final colors = context.zeroPalette;
    return RepaintBoundary(
      child: AnimatedContainer(
        key: const ValueKey('desktop-navigation-rail'),
        width: expanded
            ? ZeroTokens.sidebarExpandedWidth
            : ZeroTokens.sidebarWidth,
        duration: reduceMotion ? Duration.zero : ZeroTokens.motion,
        curve: ZeroTokens.easeSettle,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [colors.panelStrong, colors.shell],
          ),
          border: Border(right: BorderSide(color: colors.border)),
          boxShadow: colors.sidebarShadow,
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
    final colors = context.zeroPalette;
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
                    Expanded(
                      child: Text(
                        'Zero',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: TextStyle(
                          color: colors.text,
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
    final colors = context.zeroPalette;
    return Container(
      height: ZeroTokens.sidebarWidth,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [colors.panelStrong, colors.shell],
        ),
        border: Border(top: BorderSide(color: colors.border)),
        boxShadow: colors.bottomBarShadow,
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
    final colors = context.zeroPalette;
    return Row(
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors.navSelected,
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(ZeroTokens.space2),
            child: Icon(icon, color: colors.accentSoft),
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
                        'Watch history stays on this device. Connect AniList '
                        'to sync progress and pull in your list.',
                  )
                : Column(
                    key: const ValueKey('profile-accounts'),
                    children: [
                      for (final account in items)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: ZeroTokens.space2,
                          ),
                          child: _TrackingAccountRow(
                            account: account,
                            onReconnect:
                                account.service ==
                                        TrackingAccountService.aniList &&
                                    account.health !=
                                        TrackingAccountHealth.connected
                                ? () => _connectAniList(context, ref)
                                : null,
                            onDisconnect: () =>
                                _disconnect(context, ref, account),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: ZeroTokens.space3),
        if (!_hasAniList(accounts))
          Padding(
            padding: const EdgeInsets.only(bottom: ZeroTokens.space2),
            child: FilledButton.tonalIcon(
              key: const ValueKey('connect-anilist'),
              onPressed: () => _connectAniList(context, ref),
              icon: const Icon(Icons.link_rounded),
              label: const Text('Connect AniList'),
            ),
          ),
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

  bool _hasAniList(AsyncValue<List<TrackingAccount>> accounts) =>
      (accounts.value ?? const []).any(
        (account) => account.service == TrackingAccountService.aniList,
      );

  Future<void> _connectAniList(BuildContext context, WidgetRef ref) async {
    final connected = await showDialog<TrackingAccount>(
      context: context,
      builder: (_) => const _ConnectAniListDialog(),
    );
    if (connected == null || !context.mounted) return;
    ref.invalidate(trackingAccountsProvider);
    ref.invalidate(trackerWatchingProvider);
    ref.invalidate(personalizedHomeFeedProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('AniList connected as ${connected.displayName}')),
    );
  }

  Future<void> _disconnect(
    BuildContext context,
    WidgetRef ref,
    TrackingAccount account,
  ) async {
    final serviceName = switch (account.service) {
      TrackingAccountService.aniList => 'AniList',
      TrackingAccountService.myAnimeList => 'MyAnimeList',
    };
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Disconnect $serviceName?'),
        content: const Text(
          'Progress stops syncing to the tracker. Local watch history stays '
          'on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await ref.read(trackingRepositoryProvider).disconnect(account.service);
    ref.invalidate(trackingAccountsProvider);
    ref.invalidate(trackerWatchingProvider);
    ref.invalidate(personalizedHomeFeedProvider);
  }
}

/// AniList uses an implicit grant: the browser lands on a redirect address
/// whose fragment carries the access token, and the user pastes that address
/// (or the bare token) back here. No secret is involved and the token never
/// travels anywhere except to AniList itself.
const _aniListAuthorizeUrl =
    'https://anilist.co/api/v2/oauth/authorize?client_id=21788&response_type=token';

class _ConnectAniListDialog extends ConsumerStatefulWidget {
  const _ConnectAniListDialog();

  @override
  ConsumerState<_ConnectAniListDialog> createState() =>
      _ConnectAniListDialogState();
}

class _ConnectAniListDialogState extends ConsumerState<_ConnectAniListDialog> {
  final _pasted = TextEditingController();
  bool _connecting = false;
  String? _error;

  @override
  void dispose() {
    _pasted.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final text = _pasted.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'Paste the address AniList sent you to.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final account = await ref
          .read(trackingRepositoryProvider)
          .connectAniList(text);
      if (mounted) Navigator.of(context).pop(account);
    } on ArgumentError catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '${error.message}';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error =
              'AniList could not verify the token. Approve access again and '
              'paste the fresh address.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return AlertDialog(
      title: const Text('Connect AniList'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Approve Zero in the browser, then copy the address of the page '
              'you land on and paste it below.',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: colors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: ZeroTokens.space4),
            OutlinedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(_aniListAuthorizeUrl),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Open AniList'),
            ),
            const SizedBox(height: ZeroTokens.space4),
            TextField(
              key: const ValueKey('anilist-redirect'),
              controller: _pasted,
              autofocus: true,
              enabled: !_connecting,
              onSubmitted: (_) => _connect(),
              decoration: InputDecoration(
                labelText: 'Redirect address or token',
                hintText: 'shiru://alauth#access_token=…',
                errorText: _error,
                errorMaxLines: 3,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _connecting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('anilist-connect-submit'),
          onPressed: _connecting ? null : _connect,
          child: _connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
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
    final colors = context.zeroPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ZeroTokens.space4),
        child: Row(
          children: [
            Icon(icon, color: colors.textSecondary),
            const SizedBox(width: ZeroTokens.space3),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.textSecondary, height: 1.4),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

enum _TrackingAccountAction { reconnect, disconnect }

class _TrackingAccountRow extends StatelessWidget {
  const _TrackingAccountRow({
    required this.account,
    this.onReconnect,
    this.onDisconnect,
  });

  final TrackingAccount account;
  final VoidCallback? onReconnect;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
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
        colors.success,
        Icons.check_circle_outline_rounded,
      ),
      TrackingAccountHealth.attention => (
        'Reconnect soon',
        colors.warning,
        Icons.schedule_rounded,
      ),
      TrackingAccountHealth.expired => (
        'Reconnect required',
        colors.error,
        Icons.error_outline_rounded,
      ),
    };
    final actions =
        <({_TrackingAccountAction value, String label, IconData icon})>[
          if (onReconnect != null)
            (
              value: _TrackingAccountAction.reconnect,
              label: 'Reconnect',
              icon: Icons.refresh_rounded,
            ),
          if (onDisconnect != null)
            (
              value: _TrackingAccountAction.disconnect,
              label: 'Disconnect',
              icon: Icons.link_off_rounded,
            ),
        ];
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.panel,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
        border: Border.all(color: colors.border),
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
                style: TextStyle(
                  color: colors.onAccent,
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(service, style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: ZeroTokens.space1),
                  Row(
                    children: [
                      Icon(statusIcon, size: 17, color: statusColor),
                      const SizedBox(width: ZeroTokens.space1),
                      Flexible(
                        child: Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(color: statusColor),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (actions.isNotEmpty)
              PopupMenuButton<_TrackingAccountAction>(
                key: ValueKey('account-actions-${account.service.name}'),
                tooltip: 'Account actions',
                onSelected: (action) {
                  switch (action) {
                    case _TrackingAccountAction.reconnect:
                      onReconnect?.call();
                    case _TrackingAccountAction.disconnect:
                      onDisconnect?.call();
                  }
                },
                itemBuilder: (context) => [
                  for (final action in actions)
                    PopupMenuItem(
                      value: action.value,
                      child: Row(
                        children: [
                          Icon(action.icon, size: 18),
                          const SizedBox(width: ZeroTokens.space2),
                          Text(action.label),
                        ],
                      ),
                    ),
                ],
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
    final colors = context.zeroPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBase),
        border: Border.all(color: colors.border),
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
    final colors = context.zeroPalette;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ZeroTokens.radiusBrand),
        color: const Color(0xFFF7F5FF),
        border: Border.all(color: colors.accentSoft.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: colors.accent.withValues(alpha: 0.32),
            offset: const Offset(0, 4),
            blurRadius: 12,
          ),
        ],
      ),
      child: Image.asset(
        'assets/images/zero-app-icon.png',
        fit: BoxFit.cover,
        filterQuality: FilterQuality.high,
        errorBuilder: (_, _, _) =>
            Center(child: Icon(Icons.play_arrow_rounded, color: colors.accent)),
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
    final colors = context.zeroPalette;
    final d = widget.destination;
    final icon = d?.icon ?? widget.icon!;
    final label = d?.label ?? widget.label!;
    final onTap = widget.onTap ?? () => context.go(d!.path);
    final item = HoverRegion(
      cursor: SystemMouseCursors.click,
      builder: (context, hovered) {
        final iconColor = widget.active
            ? colors.accentSoft
            : (hovered ? colors.text : colors.textMuted);
        final labelColor = widget.active
            ? colors.text
            : (hovered ? colors.text : colors.textMuted);
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
                          gradient: LinearGradient(
                            begin: Alignment(-0.57, -1), // ~145deg
                            end: Alignment(0.57, 1),
                            colors: [
                              colors.navSelected,
                              colors.navSelected.withValues(alpha: 0.48),
                            ],
                          ),
                          border: Border.all(color: colors.navSelectedBorder),
                          boxShadow: colors.navigationGlow,
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
                          color: _pressed ? colors.navPress : colors.navHover,
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
