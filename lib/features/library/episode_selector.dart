import 'package:flutter/material.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/network_image.dart';
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
    this.progress = const {},
    this.onPlay,
    this.playingEpisode,
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

  /// In-episode watched fraction by episode number, for partially watched
  /// episodes only; completed ones use [watchedThrough].
  final Map<int, double> progress;
  final ValueChanged<int> onSelected;
  final ValueChanged<int>? onPlay;
  final int? playingEpisode;

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
            color: context.zeroPalette.shell.withValues(alpha: 0.72),
            border: Border.all(color: context.zeroPalette.border),
            borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
          ),
          child: Padding(
            padding: const EdgeInsets.all(ZeroTokens.space3),
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
                  onSort: (ascending) => setState(() => _ascending = ascending),
                ),
                const SizedBox(height: ZeroTokens.space3),
                _EpisodeToolbar(
                  filter: _filter,
                  onFilter: (value) => setState(() => _filter = value),
                  onQuery: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: ZeroTokens.space3),
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
    final wanted = count * rowHeight + (count - 1) * ZeroTokens.space2;
    return wanted.clamp(rowHeight, widget.maxHeight).toDouble();
  }

  Widget _list(List<int> episodes) {
    if (episodes.isEmpty) return const _NoEpisodes();
    final metadata = _metadata;
    return Scrollbar(
      child: ListView.separated(
        key: const ValueKey('episode-list'),
        padding: const EdgeInsets.fromLTRB(1, 1, ZeroTokens.space1, 1),
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(height: ZeroTokens.space2),
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
            rating: item?.rating,
            selected: episode == widget.selectedEpisode,
            watched: episode <= widget.watchedThrough,
            next: episode == widget.watchedThrough + 1,
            progress: episode <= widget.watchedThrough
                ? null
                : widget.progress[episode],
            onTap: () => widget.onSelected(episode),
            onPlay: widget.onPlay == null
                ? null
                : () => widget.onPlay!(episode),
            playing: widget.playingEpisode == episode,
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
    required this.onSort,
  });

  final String label;
  final int selected;
  final int count;
  final bool upNext;
  final bool ascending;
  final ValueChanged<bool> onSort;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 23,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                context.zeroPalette.accentHover,
                context.zeroPalette.accent,
              ],
            ),
            borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
          ),
        ),
        const SizedBox(width: ZeroTokens.space2),
        Expanded(
          child: Text(label, style: Theme.of(context).textTheme.headlineSmall),
        ),
        _CountBadge(selected: selected, count: count),
        if (upNext) ...[
          const SizedBox(width: ZeroTokens.space1),
          Text(
            'Up next',
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: context.zeroPalette.accentSoft),
          ),
        ],
        const SizedBox(width: ZeroTokens.space1),
        PopupMenuButton<bool>(
          key: const ValueKey('episode-sort'),
          tooltip: 'Sort episodes',
          initialValue: ascending,
          onSelected: onSort,
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: true,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.arrow_downward_rounded, size: 18),
                title: Text('Oldest first'),
              ),
            ),
            PopupMenuItem(
              value: false,
              child: ListTile(
                dense: true,
                leading: Icon(Icons.arrow_upward_rounded, size: 18),
                title: Text('Newest first'),
              ),
            ),
          ],
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.zeroPalette.panel,
              border: Border.all(color: context.zeroPalette.border),
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: ZeroTokens.space2,
                vertical: ZeroTokens.space1,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    ascending
                        ? Icons.arrow_downward_rounded
                        : Icons.arrow_upward_rounded,
                    size: 15,
                  ),
                  const SizedBox(width: ZeroTokens.space1),
                  Text(
                    ascending ? 'Oldest' : 'Newest',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
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
        color: context.zeroPalette.navSelected,
        border: Border.all(
          color: context.zeroPalette.accentHover.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ZeroTokens.space3,
          vertical: ZeroTokens.space1,
        ),
        child: Text(
          '$selected of $count',
          style: Theme.of(context).textTheme.labelMedium
              ?.copyWith(color: context.zeroPalette.accentSoft),
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
              const SizedBox(height: ZeroTokens.space2),
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
            const SizedBox(width: ZeroTokens.space2),
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
    required this.rating,
    required this.selected,
    required this.watched,
    required this.next,
    required this.progress,
    required this.onTap,
    required this.onPlay,
    required this.playing,
  });

  final int episode;
  final String? title;
  final String? summary;
  final String? imageUrl;
  final int? durationMinutes;
  final DateTime? airDate;
  final double? rating;
  final bool selected;
  final bool watched;
  final bool next;

  /// Watched fraction for a partially watched episode, null otherwise.
  final double? progress;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final bool playing;

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
          borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
          child: AnimatedContainer(
            height: 112,
            duration: ZeroTokens.motion,
            curve: ZeroTokens.easeSettle,
            decoration: BoxDecoration(
              color: selected
                  ? context.zeroPalette.surfaceRaised
                  : context.zeroPalette.panel,
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: context.zeroPalette.accent.withValues(
                          alpha: 0.19,
                        ),
                        blurRadius: 18,
                        spreadRadius: -5,
                      ),
                    ]
                  : null,
            ),
            // Artwork fills the row, so paint the selection ring in front of
            // it. A normal decoration border sits behind the child and loses
            // its top edge.
            foregroundDecoration: BoxDecoration(
              border: Border.all(
                color: selected
                    ? context.zeroPalette.accentHover
                    : context.zeroPalette.border,
                width: selected ? 1.4 : 1,
              ),
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPanel - 1),
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
                            left: ZeroTokens.space2,
                            bottom: ZeroTokens.space2,
                            child: _WatchedMark(),
                          ),
                        if (progress case final progress? when progress > 0)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(
                              key: ValueKey('episode-progress-$episode'),
                              value: progress,
                              minHeight: 3,
                              color: context.zeroPalette.accentHover,
                              backgroundColor: const Color(0x99000000),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        ZeroTokens.space3,
                        ZeroTokens.space3,
                        ZeroTokens.space2,
                        ZeroTokens.space2,
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
                                        color: context.zeroPalette.text,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                              ),
                              if (durationMinutes != null) ...[
                                const SizedBox(width: ZeroTokens.space2),
                                Text(
                                  '${durationMinutes}m',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
                              if (onPlay != null) ...[
                                const SizedBox(width: ZeroTokens.space2),
                                _EpisodePlayButton(
                                  episode: episode,
                                  loading: playing,
                                  onPressed: playing ? null : onPlay,
                                ),
                              ],
                            ],
                          ),
                          if (summary?.trim().isNotEmpty == true) ...[
                            const SizedBox(height: ZeroTokens.space1),
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
                                    ? context.zeroPalette.accentSoft
                                    : watched
                                    ? context.zeroPalette.success
                                    : context.zeroPalette.textMuted,
                              ),
                              const SizedBox(width: ZeroTokens.space1),
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
                                            ? context.zeroPalette.accentSoft
                                            : watched
                                            ? context.zeroPalette.success
                                            : context.zeroPalette.textMuted,
                                      ),
                                ),
                              ),
                              if (rating != null) ...[
                                Icon(
                                  Icons.star_rounded,
                                  size: 14,
                                  color: context.zeroPalette.warning,
                                ),
                                const SizedBox(width: ZeroTokens.space1),
                                Text(
                                  rating!.toStringAsFixed(1),
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ],
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

class _EpisodePlayButton extends StatelessWidget {
  const _EpisodePlayButton({
    required this.episode,
    required this.loading,
    required this.onPressed,
  });

  final int episode;
  final bool loading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: loading ? 'Finding best source' : 'Play episode $episode',
      child: Semantics(
        button: true,
        label: loading
            ? 'Finding the best source for episode $episode'
            : 'Play episode $episode using the best source',
        child: IconButton.filled(
          key: ValueKey('episode-play-$episode'),
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(
            minimumSize: const Size.square(36),
            backgroundColor: context.zeroPalette.accent,
            foregroundColor: context.zeroPalette.onAccent,
            disabledBackgroundColor: context.zeroPalette.accentDim,
          ),
          icon: loading
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.play_arrow_rounded, size: 21),
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
      return ColoredBox(
        color: context.zeroPalette.surfaceRaised,
        child: Center(
          child: Icon(
            Icons.movie_filter_outlined,
            color: context.zeroPalette.inactive,
          ),
        ),
      );
    }
    return Image(
      // A 16:9 thumbnail in a list row; decode capped well above that size.
      image: sizedNetworkImage(context, url!, logicalWidth: 280),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => ColoredBox(
        color: context.zeroPalette.surfaceRaised,
        child: Center(
          child: Icon(
            Icons.movie_filter_outlined,
            color: context.zeroPalette.inactive,
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
    final colors = context.zeroPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.18),
        border: Border.all(color: colors.success.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded, size: 12, color: colors.success),
            const SizedBox(width: 3),
            Text(
              'WATCHED',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: colors.success,
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
            ?.copyWith(color: context.zeroPalette.textMuted),
      ),
    );
  }
}
