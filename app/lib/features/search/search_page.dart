import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/empty_state.dart';
import '../../app/widgets/skeleton.dart';
import '../../application/library/providers.dart';
import '../../domain/models/catalog.dart';
import '../../domain/models/media.dart';
import '../library/media_details.dart';
import '../library/media_poster.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _items = <Media>[];

  MediaSort _sort = MediaSort.trending;
  int _nextPage = 1;
  bool _hasNextPage = true;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_loadNearEnd);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(reset: true));
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll
      ..removeListener(_loadNearEnd)
      ..dispose();
    super.dispose();
  }

  void _loadNearEnd() {
    if (_scroll.position.extentAfter < 700) _load();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading || (!reset && !_hasNextPage)) return;
    if (reset) {
      _items.clear();
      _nextPage = 1;
      _hasNextPage = true;
      _error = null;
    }
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(catalogRepositoryProvider)
          .browse(
            MediaBrowseQuery(
              search: _search.text,
              page: _nextPage,
              sort: _sort,
            ),
          );
      if (!mounted) return;
      final known = {for (final media in _items) media.id};
      _items.addAll(page.items.where((media) => known.add(media.id)));
      _hasNextPage = page.hasNextPage;
      _nextPage++;
      _error = null;
    } catch (error) {
      if (!mounted) return;
      _error = error;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _changeSort(MediaSort? value) {
    if (value == null || value == _sort) return;
    setState(() => _sort = value);
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _SearchToolbar(
          controller: _search,
          sort: _sort,
          onSortChanged: _changeSort,
          onSubmitted: (_) => _load(reset: true),
          onSearch: () => _load(reset: true),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_items.isEmpty && _loading) return const _SearchLoading();
    if (_items.isEmpty && _error != null) {
      return _SearchFailure(onRetry: () => _load(reset: true));
    }
    if (_items.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off_rounded,
        message: 'Nothing matches that search',
        detail: 'Try another title or sort.',
      );
    }

    return GridView.builder(
      key: const PageStorageKey('search-results'),
      controller: _scroll,
      padding: const EdgeInsets.all(ShiruTokens.space5),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 184,
        childAspectRatio: ShiruTokens.cardAspect,
        crossAxisSpacing: ShiruTokens.space3,
        mainAxisSpacing: ShiruTokens.space3,
      ),
      itemCount: _items.length + (_loading ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _items.length) {
          return const PosterSkeleton(width: double.infinity);
        }
        final media = _items[index];
        return LayoutBuilder(
          builder: (context, constraints) => MediaPoster(
            key: ValueKey(media.id),
            media: media,
            width: constraints.maxWidth,
            onTap: () => showMediaDetails(context, media),
          ),
        );
      },
    );
  }
}

class _SearchToolbar extends StatelessWidget {
  const _SearchToolbar({
    required this.controller,
    required this.sort,
    required this.onSortChanged,
    required this.onSubmitted,
    required this.onSearch,
  });

  final TextEditingController controller;
  final MediaSort sort;
  final ValueChanged<MediaSort?> onSortChanged;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: ShiruTokens.surfacePanelStrong,
        border: Border(bottom: BorderSide(color: ShiruTokens.surfaceBorder)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(ShiruTokens.space4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final field = TextField(
                controller: controller,
                autofocus: false,
                textInputAction: TextInputAction.search,
                onSubmitted: onSubmitted,
                decoration: const InputDecoration(
                  hintText: 'Search anime',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
              );
              final sortField = DropdownButtonFormField<MediaSort>(
                initialValue: sort,
                isExpanded: true,
                onChanged: onSortChanged,
                decoration: const InputDecoration(
                  labelText: 'Sort',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: ShiruTokens.space3,
                  ),
                ),
                items: [
                  for (final value in MediaSort.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(
                        _sortLabel(value),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              );
              final submit = IconButton.filled(
                tooltip: 'Search',
                onPressed: onSearch,
                icon: const Icon(Icons.arrow_forward_rounded),
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: field),
                        const SizedBox(width: ShiruTokens.space3),
                        submit,
                      ],
                    ),
                    const SizedBox(height: ShiruTokens.space3),
                    sortField,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: field),
                  const SizedBox(width: ShiruTokens.space3),
                  SizedBox(width: 170, child: sortField),
                  const SizedBox(width: ShiruTokens.space3),
                  submit,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static String _sortLabel(MediaSort sort) => switch (sort) {
    MediaSort.trending => 'Trending',
    MediaSort.popularity => 'Popularity',
    MediaSort.score => 'Score',
    MediaSort.title => 'Title',
    MediaSort.startDate => 'Release date',
  };
}

class _SearchLoading extends StatelessWidget {
  const _SearchLoading();

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(ShiruTokens.space5),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 184,
        childAspectRatio: ShiruTokens.cardAspect,
        crossAxisSpacing: ShiruTokens.space3,
        mainAxisSpacing: ShiruTokens.space3,
      ),
      itemCount: 18,
      itemBuilder: (_, _) => const PosterSkeleton(width: double.infinity),
    );
  }
}

class _SearchFailure extends StatelessWidget {
  const _SearchFailure({required this.onRetry});

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
