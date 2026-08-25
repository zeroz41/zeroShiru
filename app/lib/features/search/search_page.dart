import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/empty_state.dart';
import '../../app/widgets/page_motion.dart';
import '../../app/widgets/skeleton.dart';
import '../../application/library/discovery.dart';
import '../../application/library/providers.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../library/media_details.dart';
import '../library/media_poster.dart';

enum _GridDensity { compact, comfortable }

const _genres = [
  'Action',
  'Adventure',
  'Comedy',
  'Drama',
  'Fantasy',
  'Horror',
  'Mahou Shoujo',
  'Mecha',
  'Music',
  'Mystery',
  'Psychological',
  'Romance',
  'Sci-Fi',
  'Slice of Life',
  'Sports',
  'Supernatural',
  'Thriller',
];

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({
    super.key,
    this.initialGenre,
    this.initialSort,
    this.initialSeason,
    this.initialYear,
  });

  final String? initialGenre;
  final MediaSort? initialSort;
  final MediaSeason? initialSeason;
  final int? initialYear;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _items = <Media>[];

  late DiscoveryFilters _filters;
  _GridDensity _density = _GridDensity.compact;
  Timer? _searchDebounce;
  int _generation = 0;
  int _nextPage = 1;
  bool _hasNextPage = true;
  bool _loading = false;
  bool _refreshing = false;
  bool _failedRefresh = false;
  bool _filtersOpen = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _filters = DiscoveryFilters(
      sort: widget.initialSort ?? MediaSort.trending,
      season: widget.initialSeason,
      year: widget.initialYear,
      genres: widget.initialGenre == null ? const {} : {widget.initialGenre!},
    );
    _scroll.addListener(_loadNearEnd);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    _scroll
      ..removeListener(_loadNearEnd)
      ..dispose();
    super.dispose();
  }

  void _loadNearEnd() {
    if (_scroll.position.extentAfter < 800) _load();
  }

  void _searchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(
      const Duration(milliseconds: 320),
      () => _load(reset: true),
    );
  }

  void _submitSearch() {
    _searchDebounce?.cancel();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (!reset && (_loading || !_hasNextPage)) return;

    final requestGeneration = reset ? ++_generation : _generation;
    final pageNumber = reset ? 1 : _nextPage;
    setState(() {
      if (reset) {
        _nextPage = 1;
        _hasNextPage = true;
        _error = null;
        _failedRefresh = false;
        _refreshing = _items.isNotEmpty;
      }
      _loading = true;
    });

    try {
      final page = await ref
          .read(catalogRepositoryProvider)
          .browse(_filters.toQuery(search: _search.text, page: pageNumber));
      if (!mounted || requestGeneration != _generation) return;
      setState(() {
        if (reset) _items.clear();
        final known = {for (final media in _items) media.id};
        _items.addAll(page.items.where((media) => known.add(media.id)));
        _hasNextPage = page.hasNextPage;
        _nextPage = pageNumber + 1;
        _error = null;
      });
      if (reset && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.minScrollExtent);
      }
    } catch (error) {
      if (!mounted || requestGeneration != _generation) return;
      setState(() {
        _error = error;
        _failedRefresh = reset && _items.isNotEmpty;
      });
    } finally {
      if (mounted && requestGeneration == _generation) {
        setState(() {
          _loading = false;
          _refreshing = false;
        });
      }
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _search.clear();
    setState(() {});
    _load(reset: true);
  }

  void _updateFilters(DiscoveryFilters next) {
    if (identical(next, _filters)) return;
    setState(() => _filters = next);
    _load(reset: true);
  }

  void _clearFilters() => _updateFilters(const DiscoveryFilters());

  void _toggleFormat(MediaFormat value) {
    final values = {..._filters.formats};
    values.contains(value) ? values.remove(value) : values.add(value);
    _updateFilters(_filters.copyWith(formats: values));
  }

  void _toggleStatus(MediaStatus value) {
    final values = {..._filters.statuses};
    values.contains(value) ? values.remove(value) : values.add(value);
    _updateFilters(_filters.copyWith(statuses: values));
  }

  void _toggleGenre(String value) {
    final values = {..._filters.genres};
    values.contains(value) ? values.remove(value) : values.add(value);
    _updateFilters(_filters.copyWith(genres: values));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SearchToolbar(
          controller: _search,
          filters: _filters,
          filtersOpen: _filtersOpen,
          density: _density,
          resultCount: _items.length,
          loading: _loading,
          onChanged: _searchChanged,
          onSubmitted: (_) => _submitSearch(),
          onSearch: _submitSearch,
          onToggleFilters: () => setState(() => _filtersOpen = !_filtersOpen),
          onFiltersChanged: _updateFilters,
          onToggleFormat: _toggleFormat,
          onToggleStatus: _toggleStatus,
          onToggleGenre: _toggleGenre,
          onClearFilters: _clearFilters,
          onDensityChanged: (value) => setState(() => _density = value),
        ),
        Expanded(child: ShiruAnimatedSwitcher(child: _body())),
      ],
    );
  }

  Widget _body() {
    if (_items.isEmpty && _loading) {
      return _SearchLoading(key: const ValueKey('loading'), density: _density);
    }
    if (_items.isEmpty && _error != null) {
      return _SearchFailure(
        key: const ValueKey('failure'),
        onRetry: () => _load(reset: true),
      );
    }
    if (_items.isEmpty) {
      final query = _search.text.trim();
      return EmptyState(
        key: ValueKey('empty'),
        icon: Icons.search_off_rounded,
        message: query.isEmpty
            ? 'Nothing matches those filters'
            : 'No results for “$query”',
        detail: 'Try a broader title or remove one of the active filters.',
        action: Wrap(
          spacing: ShiruTokens.space2,
          runSpacing: ShiruTokens.space2,
          alignment: WrapAlignment.center,
          children: [
            if (query.isNotEmpty)
              OutlinedButton.icon(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close_rounded),
                label: const Text('Clear title'),
              ),
            if (!_filters.isDefault)
              FilledButton.tonalIcon(
                onPressed: _clearFilters,
                icon: const Icon(Icons.filter_alt_off_rounded),
                label: const Text('Reset filters'),
              ),
          ],
        ),
      );
    }

    final maxExtent = _density == _GridDensity.compact ? 178.0 : 236.0;
    return Stack(
      key: const ValueKey('results'),
      children: [
        GridView.builder(
          key: const PageStorageKey('search-results'),
          controller: _scroll,
          scrollCacheExtent: const ScrollCacheExtent.pixels(900),
          padding: const EdgeInsets.all(ShiruTokens.space5),
          gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: maxExtent,
            childAspectRatio: ShiruTokens.cardAspect,
            crossAxisSpacing: ShiruTokens.space3,
            mainAxisSpacing: ShiruTokens.space4,
          ),
          itemCount: _items.length + (_loading && !_refreshing ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _items.length) {
              return const PosterSkeleton(width: double.infinity);
            }
            final media = _items[index];
            return _ResultEntrance(
              key: ValueKey(media.id),
              order: index,
              child: LayoutBuilder(
                builder: (context, constraints) => MediaPoster(
                  media: media,
                  width: constraints.maxWidth,
                  onTap: () => showMediaDetails(context, media),
                ),
              ),
            );
          },
        ),
        if (_refreshing)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
        if (_error != null && !_loading)
          Positioned(
            left: ShiruTokens.space5,
            right: ShiruTokens.space5,
            bottom: ShiruTokens.space4,
            child: _PageLoadFailure(
              message: _failedRefresh
                  ? 'Results could not be refreshed.'
                  : 'More results could not be loaded.',
              onRetry: _failedRefresh ? () => _load(reset: true) : _load,
            ),
          ),
      ],
    );
  }
}

class _SearchToolbar extends StatelessWidget {
  const _SearchToolbar({
    required this.controller,
    required this.filters,
    required this.filtersOpen,
    required this.density,
    required this.resultCount,
    required this.loading,
    required this.onChanged,
    required this.onSubmitted,
    required this.onSearch,
    required this.onToggleFilters,
    required this.onFiltersChanged,
    required this.onToggleFormat,
    required this.onToggleStatus,
    required this.onToggleGenre,
    required this.onClearFilters,
    required this.onDensityChanged,
  });

  final TextEditingController controller;
  final DiscoveryFilters filters;
  final bool filtersOpen;
  final _GridDensity density;
  final int resultCount;
  final bool loading;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSearch;
  final VoidCallback onToggleFilters;
  final ValueChanged<DiscoveryFilters> onFiltersChanged;
  final ValueChanged<MediaFormat> onToggleFormat;
  final ValueChanged<MediaStatus> onToggleStatus;
  final ValueChanged<String> onToggleGenre;
  final VoidCallback onClearFilters;
  final ValueChanged<_GridDensity> onDensityChanged;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ShiruTokens.surfacePanelStrong,
        border: Border(bottom: BorderSide(color: ShiruTokens.surfaceBorder)),
        boxShadow: [
          BoxShadow(
            color: Color(0x40000000),
            offset: Offset(0, 7),
            blurRadius: 18,
          ),
        ],
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(ShiruTokens.space4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (context, constraints) => _ToolbarMainRow(
                  compact: constraints.maxWidth < 720,
                  controller: controller,
                  filters: filters,
                  filtersOpen: filtersOpen,
                  density: density,
                  onChanged: onChanged,
                  onSubmitted: onSubmitted,
                  onSearch: onSearch,
                  onToggleFilters: onToggleFilters,
                  onSortChanged: (sort) =>
                      onFiltersChanged(filters.copyWith(sort: sort)),
                  onDensityChanged: onDensityChanged,
                ),
              ),
              if (!filtersOpen) ...[
                const SizedBox(height: ShiruTokens.space3),
                _DiscoverPresets(
                  filters: filters,
                  onSelected: onFiltersChanged,
                ),
              ],
              AnimatedSize(
                duration: reduceMotion
                    ? Duration.zero
                    : ShiruTokens.motionPanel,
                curve: ShiruTokens.easeSettle,
                alignment: Alignment.topCenter,
                child: filtersOpen
                    ? Padding(
                        padding: const EdgeInsets.only(top: ShiruTokens.space4),
                        child: _DiscoveryPanel(
                          filters: filters,
                          onChanged: onFiltersChanged,
                          onToggleFormat: onToggleFormat,
                          onToggleStatus: onToggleStatus,
                          onToggleGenre: onToggleGenre,
                          onClear: onClearFilters,
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
              if (!filters.isDefault || resultCount > 0 || loading) ...[
                const SizedBox(height: ShiruTokens.space3),
                _FilterSummary(
                  filters: filters,
                  resultCount: resultCount,
                  loading: loading,
                  onChanged: onFiltersChanged,
                  onToggleFormat: onToggleFormat,
                  onToggleStatus: onToggleStatus,
                  onToggleGenre: onToggleGenre,
                  onClear: onClearFilters,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscoverPresets extends StatelessWidget {
  const _DiscoverPresets({required this.filters, required this.onSelected});

  final DiscoveryFilters filters;
  final ValueChanged<DiscoveryFilters> onSelected;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final currentSeason = switch (now.month) {
      <= 3 => MediaSeason.winter,
      <= 6 => MediaSeason.spring,
      <= 9 => MediaSeason.summer,
      _ => MediaSeason.fall,
    };
    final presets = <(String, IconData, DiscoveryFilters)>[
      (
        'Trending',
        Icons.local_fire_department_rounded,
        const DiscoveryFilters(),
      ),
      (
        'This season',
        Icons.calendar_view_month_rounded,
        DiscoveryFilters(season: currentSeason, year: now.year),
      ),
      (
        'Top new',
        Icons.new_releases_outlined,
        DiscoveryFilters(sort: MediaSort.popularity, year: now.year),
      ),
      (
        'Popular',
        Icons.groups_rounded,
        const DiscoveryFilters(sort: MediaSort.popularity),
      ),
      (
        'Top rated',
        Icons.star_rounded,
        const DiscoveryFilters(sort: MediaSort.score),
      ),
    ];
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: presets.length,
        separatorBuilder: (_, _) => const SizedBox(width: ShiruTokens.space2),
        itemBuilder: (context, index) {
          final preset = presets[index];
          return ActionChip(
            avatar: Icon(preset.$2, size: 16),
            label: Text(preset.$1),
            onPressed: () => onSelected(preset.$3),
          );
        },
      ),
    );
  }
}

class _ToolbarMainRow extends StatelessWidget {
  const _ToolbarMainRow({
    required this.compact,
    required this.controller,
    required this.filters,
    required this.filtersOpen,
    required this.density,
    required this.onChanged,
    required this.onSubmitted,
    required this.onSearch,
    required this.onToggleFilters,
    required this.onSortChanged,
    required this.onDensityChanged,
  });

  final bool compact;
  final TextEditingController controller;
  final DiscoveryFilters filters;
  final bool filtersOpen;
  final _GridDensity density;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSearch;
  final VoidCallback onToggleFilters;
  final ValueChanged<MediaSort> onSortChanged;
  final ValueChanged<_GridDensity> onDensityChanged;

  @override
  Widget build(BuildContext context) {
    final search = TextField(
      key: const ValueKey('search-input'),
      controller: controller,
      textInputAction: TextInputAction.search,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        hintText: 'Search anime',
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear title',
                onPressed: () {
                  controller.clear();
                  onSearch();
                },
                icon: const Icon(Icons.close_rounded),
              ),
      ),
    );
    final filter = FilledButton.tonalIcon(
      key: const ValueKey('toggle-search-filters'),
      onPressed: onToggleFilters,
      icon: Badge(
        isLabelVisible: filters.activeCount > 0,
        label: Text('${filters.activeCount}'),
        child: AnimatedRotation(
          turns: filtersOpen ? 0.5 : 0,
          duration: ShiruTokens.motion,
          child: const Icon(Icons.tune_rounded),
        ),
      ),
      label: const Text('Filters'),
    );
    final sort = _SortMenu(value: filters.sort, onChanged: onSortChanged);
    final densityControl = _DensityControl(
      value: density,
      onChanged: onDensityChanged,
    );
    final submit = IconButton.filled(
      tooltip: 'Search',
      onPressed: onSearch,
      icon: const Icon(Icons.arrow_forward_rounded),
    );

    if (compact) {
      return Column(
        children: [
          Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: ShiruTokens.space3),
              submit,
            ],
          ),
          const SizedBox(height: ShiruTokens.space3),
          Row(
            children: [
              Expanded(child: filter),
              const SizedBox(width: ShiruTokens.space2),
              Expanded(child: sort),
              const SizedBox(width: ShiruTokens.space2),
              densityControl,
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: search),
        const SizedBox(width: ShiruTokens.space3),
        filter,
        const SizedBox(width: ShiruTokens.space2),
        SizedBox(width: 170, child: sort),
        const SizedBox(width: ShiruTokens.space2),
        densityControl,
        const SizedBox(width: ShiruTokens.space2),
        submit,
      ],
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.value, required this.onChanged});

  final MediaSort value;
  final ValueChanged<MediaSort> onChanged;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      useRootOverlay: true,
      animated: true,
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ShiruTokens.darkLight),
        side: WidgetStatePropertyAll(
          BorderSide(color: ShiruTokens.surfaceBorder),
        ),
      ),
      menuChildren: [
        for (final sort in MediaSort.values)
          MenuItemButton(
            leadingIcon: Icon(
              sort == value
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: sort == value
                  ? ShiruTokens.accentVeryLight
                  : ShiruTokens.textMuted,
            ),
            onPressed: () => onChanged(sort),
            child: Text(_sortLabel(sort)),
          ),
      ],
      builder: (context, controller, child) => OutlinedButton.icon(
        key: const ValueKey('search-sort-menu'),
        onPressed: controller.open,
        icon: const Icon(Icons.sort_rounded),
        label: Text(
          _sortLabel(value),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

class _DensityControl extends StatelessWidget {
  const _DensityControl({required this.value, required this.onChanged});

  final _GridDensity value;
  final ValueChanged<_GridDensity> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_GridDensity>(
      key: const ValueKey('search-density'),
      showSelectedIcon: false,
      selected: {value},
      onSelectionChanged: (selected) => onChanged(selected.single),
      segments: const [
        ButtonSegment(
          value: _GridDensity.compact,
          icon: Tooltip(
            message: 'Compact posters',
            child: Icon(Icons.grid_view_rounded, size: 18),
          ),
        ),
        ButtonSegment(
          value: _GridDensity.comfortable,
          icon: Tooltip(
            message: 'Comfortable posters',
            child: Icon(Icons.grid_on_rounded, size: 18),
          ),
        ),
      ],
    );
  }
}

class _DiscoveryPanel extends StatelessWidget {
  const _DiscoveryPanel({
    required this.filters,
    required this.onChanged,
    required this.onToggleFormat,
    required this.onToggleStatus,
    required this.onToggleGenre,
    required this.onClear,
  });

  final DiscoveryFilters filters;
  final ValueChanged<DiscoveryFilters> onChanged;
  final ValueChanged<MediaFormat> onToggleFormat;
  final ValueChanged<MediaStatus> onToggleStatus;
  final ValueChanged<String> onToggleGenre;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final currentYear = DateTime.now().year;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0x9917191C),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
        border: Border.all(color: ShiruTokens.surfaceBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(ShiruTokens.space4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: ShiruTokens.space3,
              runSpacing: ShiruTokens.space3,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 170,
                  child: _SelectMenu<MediaSeason>(
                    label: 'Season',
                    value: filters.season,
                    values: MediaSeason.values,
                    valueLabel: _seasonLabel,
                    onChanged: (value) =>
                        onChanged(filters.copyWith(season: value)),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: _SelectMenu<int>(
                    label: 'Year',
                    value: filters.year,
                    values: [
                      for (var year = currentYear + 1; year >= 1970; year--)
                        year,
                    ],
                    valueLabel: (value) => '$value',
                    onChanged: (value) =>
                        onChanged(filters.copyWith(year: value)),
                  ),
                ),
                FilterChip(
                  label: const Text('Hide my anime'),
                  avatar: const Icon(Icons.visibility_off_outlined, size: 17),
                  selected: filters.hideMyAnime,
                  onSelected: (value) =>
                      onChanged(filters.copyWith(hideMyAnime: value)),
                ),
                FilterChip(
                  label: const Text('Adult titles'),
                  avatar: const Icon(Icons.no_adult_content_outlined, size: 17),
                  selected: filters.includeAdult,
                  onSelected: (value) =>
                      onChanged(filters.copyWith(includeAdult: value)),
                ),
                if (!filters.isDefault)
                  TextButton.icon(
                    onPressed: onClear,
                    icon: const Icon(Icons.filter_alt_off_rounded),
                    label: const Text('Reset filters'),
                  ),
              ],
            ),
            const SizedBox(height: ShiruTokens.space4),
            _FilterGroup(
              title: 'Format',
              children: [
                for (final format in const [
                  MediaFormat.tv,
                  MediaFormat.tvShort,
                  MediaFormat.movie,
                  MediaFormat.ona,
                  MediaFormat.ova,
                  MediaFormat.special,
                  MediaFormat.music,
                ])
                  FilterChip(
                    label: Text(_formatLabel(format)),
                    selected: filters.formats.contains(format),
                    onSelected: (_) => onToggleFormat(format),
                  ),
              ],
            ),
            const SizedBox(height: ShiruTokens.space3),
            _FilterGroup(
              title: 'Status',
              children: [
                for (final status in MediaStatus.values)
                  FilterChip(
                    label: Text(_statusLabel(status)),
                    selected: filters.statuses.contains(status),
                    onSelected: (_) => onToggleStatus(status),
                  ),
              ],
            ),
            const SizedBox(height: ShiruTokens.space3),
            _FilterGroup(
              title: 'Genres',
              children: [
                for (final genre in _genres)
                  FilterChip(
                    label: Text(genre),
                    selected: filters.genres.contains(genre),
                    onSelected: (_) => onToggleGenre(genre),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SelectMenu<T> extends StatelessWidget {
  const _SelectMenu({
    required this.label,
    required this.value,
    required this.values,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final T? value;
  final List<T> values;
  final String Function(T value) valueLabel;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      useRootOverlay: true,
      animated: true,
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(ShiruTokens.darkLight),
        maximumSize: WidgetStatePropertyAll(Size(260, 360)),
      ),
      menuChildren: [
        MenuItemButton(
          leadingIcon: Icon(
            value == null ? Icons.check_rounded : Icons.remove_rounded,
          ),
          onPressed: () => onChanged(null),
          child: const Text('Any'),
        ),
        for (final item in values)
          MenuItemButton(
            leadingIcon: Icon(
              item == value ? Icons.check_rounded : Icons.remove_rounded,
              color: item == value
                  ? ShiruTokens.accentVeryLight
                  : Colors.transparent,
            ),
            onPressed: () => onChanged(item),
            child: Text(valueLabel(item)),
          ),
      ],
      builder: (context, controller, child) => OutlinedButton(
        onPressed: controller.open,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelSmall),
                  Text(value == null ? 'Any' : valueLabel(value as T)),
                ],
              ),
            ),
            const Icon(Icons.expand_more_rounded),
          ],
        ),
      ),
    );
  }
}

class _FilterGroup extends StatelessWidget {
  const _FilterGroup({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 74,
          child: Padding(
            padding: const EdgeInsets.only(top: ShiruTokens.space2),
            child: Text(title, style: Theme.of(context).textTheme.titleSmall),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: ShiruTokens.space2,
            runSpacing: ShiruTokens.space1,
            children: children,
          ),
        ),
      ],
    );
  }
}

class _FilterSummary extends StatelessWidget {
  const _FilterSummary({
    required this.filters,
    required this.resultCount,
    required this.loading,
    required this.onChanged,
    required this.onToggleFormat,
    required this.onToggleStatus,
    required this.onToggleGenre,
    required this.onClear,
  });

  final DiscoveryFilters filters;
  final int resultCount;
  final bool loading;
  final ValueChanged<DiscoveryFilters> onChanged;
  final ValueChanged<MediaFormat> onToggleFormat;
  final ValueChanged<MediaStatus> onToggleStatus;
  final ValueChanged<String> onToggleGenre;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (loading)
          const Padding(
            padding: EdgeInsets.only(right: ShiruTokens.space3),
            child: SizedBox.square(
              dimension: 15,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(right: ShiruTokens.space3),
            child: Text(
              resultCount == 0 ? 'Discover' : '$resultCount loaded',
              style: Theme.of(context).textTheme.labelMedium
                  ?.copyWith(color: ShiruTokens.textLight),
            ),
          ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (filters.sort != MediaSort.trending)
                  _ActiveFilterChip(
                    label: _sortLabel(filters.sort),
                    onDeleted: () =>
                        onChanged(filters.copyWith(sort: MediaSort.trending)),
                  ),
                if (filters.season != null)
                  _ActiveFilterChip(
                    label: _seasonLabel(filters.season!),
                    onDeleted: () => onChanged(filters.copyWith(season: null)),
                  ),
                if (filters.year != null)
                  _ActiveFilterChip(
                    label: '${filters.year}',
                    onDeleted: () => onChanged(filters.copyWith(year: null)),
                  ),
                for (final format in filters.formats)
                  _ActiveFilterChip(
                    label: _formatLabel(format),
                    onDeleted: () => onToggleFormat(format),
                  ),
                for (final status in filters.statuses)
                  _ActiveFilterChip(
                    label: _statusLabel(status),
                    onDeleted: () => onToggleStatus(status),
                  ),
                for (final genre in filters.genres)
                  _ActiveFilterChip(
                    label: genre,
                    onDeleted: () => onToggleGenre(genre),
                  ),
                if (filters.hideMyAnime)
                  _ActiveFilterChip(
                    label: 'Hide my anime',
                    onDeleted: () =>
                        onChanged(filters.copyWith(hideMyAnime: false)),
                  ),
                if (filters.includeAdult)
                  _ActiveFilterChip(
                    label: 'Adult titles',
                    onDeleted: () =>
                        onChanged(filters.copyWith(includeAdult: false)),
                  ),
              ],
            ),
          ),
        ),
        if (!filters.isDefault)
          IconButton(
            tooltip: 'Reset all filters',
            onPressed: onClear,
            icon: const Icon(Icons.filter_alt_off_rounded),
          ),
      ],
    );
  }
}

class _ActiveFilterChip extends StatelessWidget {
  const _ActiveFilterChip({required this.label, required this.onDeleted});

  final String label;
  final VoidCallback onDeleted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: ShiruTokens.space2),
      child: InputChip(
        visualDensity: VisualDensity.compact,
        label: Text(label),
        onDeleted: onDeleted,
        deleteIcon: const Icon(Icons.close_rounded, size: 15),
      ),
    );
  }
}

class _ResultEntrance extends StatelessWidget {
  const _ResultEntrance({super.key, required this.order, required this.child});

  final int order;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reduceMotion
          ? Duration.zero
          : Duration(milliseconds: 260 + order.clamp(0, 7) * 24),
      curve: ShiruTokens.easeSettle,
      child: RepaintBoundary(child: child),
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, (1 - value) * 12),
          child: child,
        ),
      ),
    );
  }
}

class _SearchLoading extends StatelessWidget {
  const _SearchLoading({super.key, required this.density});

  final _GridDensity density;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(ShiruTokens.space5),
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: density == _GridDensity.compact ? 178 : 236,
        childAspectRatio: ShiruTokens.cardAspect,
        crossAxisSpacing: ShiruTokens.space3,
        mainAxisSpacing: ShiruTokens.space4,
      ),
      itemCount: 18,
      itemBuilder: (_, _) => const PosterSkeleton(width: double.infinity),
    );
  }
}

class _SearchFailure extends StatelessWidget {
  const _SearchFailure({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(
            icon: Icons.cloud_off_rounded,
            message: 'Search is unavailable',
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

class _PageLoadFailure extends StatelessWidget {
  const _PageLoadFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ShiruTokens.darkLight,
      elevation: 8,
      borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
      child: Padding(
        padding: const EdgeInsets.only(left: ShiruTokens.space4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 18),
            const SizedBox(width: ShiruTokens.space2),
            Expanded(child: Text(message)),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

String _sortLabel(MediaSort sort) => switch (sort) {
  MediaSort.trending => 'Trending',
  MediaSort.popularity => 'Popularity',
  MediaSort.score => 'Highest score',
  MediaSort.title => 'Title',
  MediaSort.startDate => 'Release date',
};

String _seasonLabel(MediaSeason season) => switch (season) {
  MediaSeason.winter => 'Winter',
  MediaSeason.spring => 'Spring',
  MediaSeason.summer => 'Summer',
  MediaSeason.fall => 'Fall',
};

String _formatLabel(MediaFormat format) => switch (format) {
  MediaFormat.tv => 'TV',
  MediaFormat.tvShort => 'TV short',
  MediaFormat.movie => 'Movie',
  MediaFormat.special => 'Special',
  MediaFormat.ova => 'OVA',
  MediaFormat.ona => 'ONA',
  MediaFormat.music => 'Music',
  MediaFormat.unknown => 'Other',
};

String _statusLabel(MediaStatus status) => switch (status) {
  MediaStatus.finished => 'Finished',
  MediaStatus.releasing => 'Airing',
  MediaStatus.notYetReleased => 'Upcoming',
  MediaStatus.cancelled => 'Cancelled',
  MediaStatus.hiatus => 'Hiatus',
};
