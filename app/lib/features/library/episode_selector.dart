import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../domain/models/media.dart';

enum EpisodeFilter { all, unwatched, watched }

/// Optional presentation data for an episode row.
///
/// The selector remains useful with only an episode number. Metadata can
/// arrive later without replacing the list or changing what a click means.
/// A virtualized, artwork-led episode browser.
///
/// It is intentionally a list instead of a grid: artwork, title, watch state,
/// and duration remain readable at the same time.
class EpisodeSelector extends StatefulWidget {
  const EpisodeSelector({
    super.key,
    required this.episodeCount,
    required this.selectedEpisode,
    required this.onSelected,
    this.watchedThrough = 0,
    this.label = 'Episodes',
    this.maxHeight = 560,
    this.expanded = false,
    this.fallbackArtwork,
    this.durationMinutes,
    this.items = const [],
  });

  final int episodeCount;
  final int selectedEpisode;
  final int watchedThrough;
  final String label;
  final double maxHeight;
  final bool expanded;
  final String? fallbackArtwork;
  final int? durationMinutes;
  final List<EpisodeInfo> items;
  final ValueChanged<int> onSelected;

  @override
  State<EpisodeSelector> createState() => _EpisodeSelectorState();
}

class _EpisodeSelectorState extends State<EpisodeSelector> {
  EpisodeFilter _filter = EpisodeFilter.all;
  String _query = '';
  bool _ascending = true;

  Map<int, EpisodeInfo> get _metadata => {
    for (final item in widget.items) item.number: item,
  };

  List<int> get _episodes {
    final normalizedQuery = _query.trim().toLowerCase();
    final metadata = _metadata;
    final episodes = [
      for (var episode = 1; episode <= widget.episodeCount; episode++)
        if (_matchesFilter(episode) &&
            (normalizedQuery.isEmpty ||
                '$episode'.contains(normalizedQuery) ||
                (metadata[episode]?.title?.toLowerCase().contains(
                      normalizedQuery,
                    ) ??
                    false)))
          episode,
    ];
    return _ascending ? episodes : episodes.reversed.toList(growable: false);
  }

  bool _matchesFilter(int episode) => switch (_filter) {
    EpisodeFilter.all => true,
    EpisodeFilter.unwatched => episode > widget.watchedThrough,
    EpisodeFilter.watched => episode <= widget.watchedThrough,
  };

  @override
  Widget build(BuildContext context) {
    final episodes = _episodes;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fillAvailable = widget.expanded || constraints.maxHeight.isFinite;
        final content = DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xB8121416),
            border: Border.all(color: ShiruTokens.surfaceBorder),
            borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
          ),
          child: Padding(
            padding: const EdgeInsets.all(ShiruTokens.space3),
            child: Column(
              mainAxisSize: fillAvailable ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _EpisodeHeader(
                  label: widget.label,
                  selected: widget.selectedEpisode,
                  count: widget.episodeCount,
                  upNext: widget.selectedEpisode == widget.watchedThrough + 1,
                  ascending: _ascending,
                  onReverse: () => setState(() => _ascending = !_ascending),
                ),
                const SizedBox(height: ShiruTokens.space3),
                _EpisodeToolbar(
                  filter: _filter,
                  onFilter: (value) => setState(() => _filter = value),
                  onQuery: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: ShiruTokens.space3),
                if (fillAvailable)
                  Expanded(child: _list(episodes))
                else
                  SizedBox(
                    height: _listHeight(episodes.length),
                    child: _list(episodes),
                  ),
              ],
            ),
          ),
        );
        return widget.expanded ? SizedBox.expand(child: content) : content;
      },
    );
  }

  double _listHeight(int count) {
    if (count == 0) return 104;
    const rowHeight = 112.0;
    final wanted = count * rowHeight + (count - 1) * ShiruTokens.space2;
    return wanted.clamp(rowHeight, widget.maxHeight).toDouble();
  }

  Widget _list(List<int> episodes) {
    if (episodes.isEmpty) return const _NoEpisodes();
    final metadata = _metadata;
    return Scrollbar(
      child: ListView.separated(
        key: const ValueKey('episode-list'),
        padding: const EdgeInsets.only(right: ShiruTokens.space1),
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(height: ShiruTokens.space2),
        itemBuilder: (context, index) {
          final episode = episodes[index];
          final item = metadata[episode];
          return _EpisodeRow(
            key: ValueKey('episode-$episode'),
            episode: episode,
            title: item?.title,
            summary: item?.summary,
            imageUrl: item?.imageUrl ?? widget.fallbackArtwork,
            durationMinutes: item?.durationMinutes ?? widget.durationMinutes,
            airDate: item?.airDate,
            selected: episode == widget.selectedEpisode,
            watched: episode <= widget.watchedThrough,
            next: episode == widget.watchedThrough + 1,
            onTap: () => widget.onSelected(episode),
          );
        },
      ),
    );
  }
}

class _EpisodeHeader extends StatelessWidget {
  const _EpisodeHeader({
    required this.label,
    required this.selected,
    required this.count,
    required this.upNext,
    required this.ascending,
    required this.onReverse,
  });

  final String label;
  final int selected;
  final int count;
  final bool upNext;
  final bool ascending;
  final VoidCallback onReverse;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 23,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [ShiruTokens.accentLight, ShiruTokens.accent],
            ),
            borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
          ),
        ),
        const SizedBox(width: ShiruTokens.space2),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.headlineSmall),
        ),
        _CountBadge(selected: selected, count: count),
        if (upNext) ...[
          const SizedBox(width: ShiruTokens.space1),
          Text(
            'Up next',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: ShiruTokens.accentVeryLight),
          ),
        ],
        const SizedBox(width: ShiruTokens.space1),
        IconButton(
          tooltip: ascending ? 'Newest first' : 'Oldest first',
          onPressed: onReverse,
          icon: Icon(
            ascending ? Icons.south_rounded : Icons.north_rounded,
            size: 19,
          ),
        ),
      ],
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.selected, required this.count});

  final int selected;
  final int count;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x292F75E4),
        border: Border.all(color: const Color(0x665D93EA)),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.space3,
          vertical: ShiruTokens.space1,
        ),
        child: Text(
          '$selected of $count',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: ShiruTokens.accentVeryLight),
        ),
      ),
    );
  }
}

class _EpisodeToolbar extends StatelessWidget {
  const _EpisodeToolbar({
    required this.filter,
    required this.onFilter,
    required this.onQuery,
  });

  final EpisodeFilter filter;
  final ValueChanged<EpisodeFilter> onFilter;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        final search = SizedBox(
          width: compact ? double.infinity : 165,
          height: 38,
          child: TextField(
            key: const ValueKey('episode-search'),
            onChanged: onQuery,
            decoration: const InputDecoration(
              hintText: 'Find episode',
              prefixIcon: Icon(Icons.search_rounded, size: 18),
            ),
          ),
        );
        final filters = SegmentedButton<EpisodeFilter>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: EpisodeFilter.all, label: Text('All')),
            ButtonSegment(
              value: EpisodeFilter.unwatched,
              label: Text('Unwatched'),
            ),
            ButtonSegment(value: EpisodeFilter.watched, label: Text('Watched')),
          ],
          selected: {filter},
          onSelectionChanged: (selection) => onFilter(selection.single),
        );
        if (compact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              const SizedBox(height: ShiruTokens.space2),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: filters,
              ),
            ],
          );
        }
        return Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: filters,
              ),
            ),
            const SizedBox(width: ShiruTokens.space2),
            search,
          ],
        );
      },
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.title,
    required this.summary,
    required this.imageUrl,
    required this.durationMinutes,
    required this.airDate,
    required this.selected,
    required this.watched,
    required this.next,
    required this.onTap,
  });

  final int episode;
  final String? title;
  final String? summary;
  final String? imageUrl;
  final int? durationMinutes;
  final DateTime? airDate;
  final bool selected;
  final bool watched;
  final bool next;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final status = watched ? 'Watched' : (next ? 'Up next' : 'Ready to watch');
    return Semantics(
      button: true,
      selected: selected,
      label: 'Episode $episode, $status',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
          child: AnimatedContainer(
            height: 112,
            duration: ShiruTokens.motion,
            curve: ShiruTokens.easeSettle,
            decoration: BoxDecoration(
              color: selected
                  ? const Color(0xE6262E3A)
                  : ShiruTokens.surfacePanel,
              border: Border.all(
                color: selected
                    ? ShiruTokens.accentLight
                    : ShiruTokens.surfaceBorder,
                width: selected ? 1.4 : 1,
              ),
              borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
              boxShadow: selected
                  ? const [
                      BoxShadow(
                        color: Color(0x302F75E4),
                        blurRadius: 18,
                        spreadRadius: -5,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel - 1),
              child: Row(
                children: [
                  AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _EpisodeArtwork(url: imageUrl),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [Color(0x08000000), Color(0x99202327)],
                            ),
                          ),
                        ),
                        if (watched)
                          const Positioned(
                            left: ShiruTokens.space2,
                            bottom: ShiruTokens.space2,
                            child: _WatchedMark(),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        ShiruTokens.space3,
                        ShiruTokens.space3,
                        ShiruTokens.space2,
                        ShiruTokens.space2,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title?.trim().isNotEmpty == true
                                      ? '$episode. $title'
                                      : 'Episode $episode',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: ShiruTokens.highlight,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                              ),
                              if (durationMinutes != null) ...[
                                const SizedBox(width: ShiruTokens.space2),
                                Text(
                                  '${durationMinutes}m',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                            ],
                          ),
                          if (summary?.trim().isNotEmpty == true) ...[
                            const SizedBox(height: ShiruTokens.space1),
                            Text(
                              summary!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(height: 1.3),
                            ),
                          ],
                          const Spacer(),
                          Row(
                            children: [
                              Icon(
                                next
                                    ? Icons.play_circle_fill_rounded
                                    : watched
                                    ? Icons.check_circle_rounded
                                    : Icons.play_circle_outline_rounded,
                                size: 15,
                                color: next || selected
                                    ? ShiruTokens.accentVeryLight
                                    : watched
                                    ? ShiruTokens.completed
                                    : ShiruTokens.textMuted,
                              ),
                              const SizedBox(width: ShiruTokens.space1),
                              Expanded(
                                child: Text(
                                  airDate == null
                                      ? status
                                      : '${airDate!.year}-${airDate!.month.toString().padLeft(2, '0')}-${airDate!.day.toString().padLeft(2, '0')}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall
                                      ?.copyWith(
                                        color: next || selected
                                            ? ShiruTokens.accentVeryLight
                                            : watched
                                            ? ShiruTokens.completed
                                            : ShiruTokens.textMuted,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EpisodeArtwork extends StatelessWidget {
  const _EpisodeArtwork({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return const ColoredBox(
        color: ShiruTokens.darkVeryLight,
        child: Center(
          child: Icon(
            Icons.movie_filter_outlined,
            color: ShiruTokens.grayVeryDim,
          ),
        ),
      );
    }
    return Image(
      image: CachedNetworkImageProvider(url!),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const ColoredBox(
        color: ShiruTokens.darkVeryLight,
        child: Center(
          child: Icon(
            Icons.movie_filter_outlined,
            color: ShiruTokens.grayVeryDim,
          ),
        ),
      ),
    );
  }
}

class _WatchedMark extends StatelessWidget {
  const _WatchedMark();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD90A160A),
        border: Border.all(color: const Color(0x8069D454)),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded, size: 12, color: ShiruTokens.completed),
            SizedBox(width: 3),
            Text(
              'WATCHED',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: ShiruTokens.completed,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoEpisodes extends StatelessWidget {
  const _NoEpisodes();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No episodes match this view.',
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(color: ShiruTokens.textMuted),
      ),
    );
  }
}
