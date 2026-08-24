import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../application/settings/providers.dart';
import '../../domain/models/settings.dart';

class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider).value;
    return CustomScrollView(
      key: const PageStorageKey('downloads-scroll'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            ShiruTokens.space6,
            ShiruTokens.space7,
            ShiruTokens.space6,
            ShiruTokens.space3,
          ),
          sliver: const SliverToBoxAdapter(child: _Header()),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            ShiruTokens.space6,
            ShiruTokens.space3,
            ShiruTokens.space6,
            ShiruTokens.space7,
          ),
          sliver: SliverToBoxAdapter(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _EmptyTransferPanel(),
                  if (settings != null) ...[
                    const SizedBox(height: ShiruTokens.space4),
                    _TransferDefaults(settings: settings),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Downloads',
                  style: Theme.of(context).textTheme.displayMedium,
                ),
                const SizedBox(height: ShiruTokens.space2),
                Text(
                  'Active transfers, completed files, and seeding sessions.',
                  style: Theme.of(context).textTheme.bodyLarge
                      ?.copyWith(color: ShiruTokens.textLight),
                ),
              ],
            ),
          ),
          const SizedBox(width: ShiruTokens.space4),
          OutlinedButton.icon(
            onPressed: () => context.go('/settings'),
            icon: const Icon(Icons.tune_rounded, size: 18),
            label: const Text('Transfer settings'),
          ),
        ],
      ),
    );
  }
}

class _EmptyTransferPanel extends StatelessWidget {
  const _EmptyTransferPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
        border: Border.all(color: ShiruTokens.surfaceBorder),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [ShiruTokens.surfacePanel, Color(0x8017191C)],
        ),
        boxShadow: ShiruTokens.cardShadow,
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(ShiruTokens.space7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0x202F75E4),
                  border: Border.all(color: const Color(0x592F75E4)),
                ),
                child: const Icon(
                  Icons.download_done_rounded,
                  size: 30,
                  color: ShiruTokens.accentVeryLight,
                ),
              ),
              const SizedBox(height: ShiruTokens.space4),
              Text(
                'No local transfers',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: ShiruTokens.space2),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Text(
                  'Torrent-backed episodes appear here while they download or seed. '
                  'Direct debrid streams stay remote and do not create a local transfer.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(color: ShiruTokens.textLight, height: 1.45),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TransferDefaults extends StatelessWidget {
  const _TransferDefaults({required this.settings});

  final Settings settings;

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
        child: Wrap(
          spacing: ShiruTokens.space4,
          runSpacing: ShiruTokens.space3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Transfer defaults',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            _DefaultChip(
              icon: Icons.speed_rounded,
              label: _rate(settings.torrentSpeedBytes),
            ),
            _DefaultChip(
              icon: Icons.hub_outlined,
              label: '${settings.maxConnections} peers',
            ),
            _DefaultChip(
              icon: settings.torrentPersist
                  ? Icons.inventory_2_outlined
                  : Icons.auto_delete_outlined,
              label: settings.torrentPersist
                  ? 'Keep completed files'
                  : 'Clean up after playback',
            ),
          ],
        ),
      ),
    );
  }

  static String _rate(int bytes) {
    const mib = 1024 * 1024;
    return '${bytes ~/ mib} MiB/s limit';
  }
}

class _DefaultChip extends StatelessWidget {
  const _DefaultChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShiruTokens.darkVeryLight,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
        border: Border.all(color: ShiruTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.space3,
          vertical: ShiruTokens.space2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: ShiruTokens.accentVeryLight),
            const SizedBox(width: ShiruTokens.space2),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
    );
  }
}
