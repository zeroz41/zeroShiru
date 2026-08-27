import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/empty_state.dart';
import '../../app/widgets/skeleton.dart';
import '../../application/library/providers.dart';
import '../../domain/models/media.dart';
import '../library/media_details.dart';
import '../library/media_poster.dart';

class SchedulePage extends ConsumerStatefulWidget {
  const SchedulePage({super.key});

  @override
  ConsumerState<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends ConsumerState<SchedulePage> {
  final _filterController = TextEditingController();
  String _filter = '';

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _refresh() => ref.invalidate(upcomingScheduleProvider);

  @override
  Widget build(BuildContext context) {
    final schedule = ref.watch(upcomingScheduleProvider);
    return Column(
      children: [
        _ScheduleToolbar(
          controller: _filterController,
          onChanged: (value) => setState(() => _filter = value.trim()),
          onRefresh: _refresh,
          refreshing: schedule.isLoading,
        ),
        Expanded(
          child: schedule.when(
            loading: () => const _ScheduleLoading(),
            error: (_, _) => _ScheduleFailure(onRetry: _refresh),
            data: (items) {
              final visible = _filterSchedule(items, _filter);
              if (items.isEmpty) {
                return const EmptyState(
                  icon: Icons.event_busy_rounded,
                  message: 'No upcoming episodes',
                  detail: 'New broadcasts will appear here when announced.',
                );
              }
              if (visible.isEmpty) {
                return const EmptyState(
                  icon: Icons.search_off_rounded,
                  message: 'No scheduled anime match that filter',
                  detail: 'Try another title.',
                );
              }
              return _ScheduleResults(items: visible);
            },
          ),
        ),
      ],
    );
  }
}

List<Media> _filterSchedule(List<Media> items, String filter) {
  final needle = filter.toLowerCase();
  if (needle.isEmpty) return items;
  return items
      .where(
        (media) => <String>[
          media.title.display,
          ...media.synonyms,
        ].any((title) => title.toLowerCase().contains(needle)),
      )
      .toList(growable: false);
}

class _ScheduleToolbar extends StatelessWidget {
  const _ScheduleToolbar({
    required this.controller,
    required this.onChanged,
    required this.onRefresh,
    required this.refreshing,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onRefresh;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: context.zeroPalette.panelStrong,
        border: Border(bottom: BorderSide(color: context.zeroPalette.border)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(ZeroTokens.space4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Schedule',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text(
                    'Upcoming TV episodes, ordered by airtime.',
                    style: Theme.of(context).textTheme.bodyMedium
                        ?.copyWith(color: context.zeroPalette.textSecondary),
                  ),
                ],
              );
              final filter = TextField(
                key: const ValueKey('schedule-filter'),
                controller: controller,
                onChanged: onChanged,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Filter schedule',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              );
              final refresh = IconButton.filledTonal(
                key: const ValueKey('refresh-schedule'),
                tooltip: refreshing
                    ? 'Refreshing schedule'
                    : 'Refresh schedule',
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded),
              );

              if (constraints.maxWidth < 620) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    heading,
                    const SizedBox(height: ZeroTokens.space3),
                    Row(
                      children: [
                        Expanded(child: filter),
                        const SizedBox(width: ZeroTokens.space3),
                        refresh,
                      ],
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: heading),
                  SizedBox(width: 300, child: filter),
                  const SizedBox(width: ZeroTokens.space3),
                  refresh,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Owns the page's single clock. Every card receives the same timestamp, so a
/// large schedule does not create one timer per poster or show split-second
/// inconsistencies between countdowns.
class _ScheduleResults extends StatefulWidget {
  const _ScheduleResults({required this.items});

  final List<Media> items;

  @override
  State<_ScheduleResults> createState() => _ScheduleResultsState();
}

class _ScheduleResultsState extends State<_ScheduleResults> {
  late DateTime _now;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      // The shell keeps this tab alive while another one is visible;
      // countdowns only need to be current when the grid can be seen.
      if (mounted && _visible) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    // Catch up after the tab was hidden through one or more skipped ticks.
    _now = DateTime.now();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      key: const PageStorageKey('schedule-results'),
      padding: const EdgeInsets.all(ZeroTokens.space5),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        childAspectRatio: 0.45,
        crossAxisSpacing: ZeroTokens.space3,
        mainAxisSpacing: ZeroTokens.space4,
      ),
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        final media = widget.items[index];
        return _ScheduleCard(key: ValueKey(media.id), media: media, now: _now);
      },
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({super.key, required this.media, required this.now});

  final Media media;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final airing = media.nextAiringEpisode!;
    final countdown = formatAiringCountdown(airing.airingAt, now);
    return Semantics(
      label: '${media.title.display}, episode ${airing.episode}, $countdown',
      child: Column(
        children: [
          SizedBox(
            height: 38,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Episode ${airing.episode} in',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: context.zeroPalette.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  countdown,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: countdown == 'Airing now'
                        ? context.zeroPalette.success
                        : context.zeroPalette.text,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => MediaPoster(
                media: media,
                width: constraints.maxWidth,
                onTap: () => showMediaDetails(context, media),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String formatAiringCountdown(DateTime airingAt, DateTime now) {
  final remaining = airingAt.difference(now);
  if (remaining <= Duration.zero) return 'Airing now';
  if (remaining < const Duration(minutes: 1)) return '<1m';

  final days = remaining.inDays;
  final hours = remaining.inHours.remainder(24);
  final minutes = remaining.inMinutes.remainder(60);
  if (days > 0) return '${days}d ${hours}h';
  if (remaining.inHours > 0) return '${remaining.inHours}h ${minutes}m';
  return '${remaining.inMinutes}m';
}

class _ScheduleLoading extends StatelessWidget {
  const _ScheduleLoading();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(ZeroTokens.space5),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 190,
        childAspectRatio: 0.45,
        crossAxisSpacing: ZeroTokens.space3,
        mainAxisSpacing: ZeroTokens.space4,
      ),
      itemCount: 18,
      itemBuilder: (_, _) => const Column(
        children: [
          Padding(
            padding: EdgeInsets.symmetric(vertical: ZeroTokens.space2),
            child: Skeleton(width: 72, height: 22),
          ),
          Expanded(child: PosterSkeleton(width: double.infinity)),
        ],
      ),
    );
  }
}

class _ScheduleFailure extends StatelessWidget {
  const _ScheduleFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(
            icon: Icons.cloud_off_rounded,
            message: 'Schedule is unavailable',
            detail: 'The service did not answer this request.',
          ),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Try again'),
          ),
        ],
      ),
    );
  }
}
