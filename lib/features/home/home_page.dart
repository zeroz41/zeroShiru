import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/empty_state.dart';
import '../../app/widgets/skeleton.dart';
import '../../app/widgets/titled_rail.dart';
import '../../application/library/providers.dart';
import '../../domain/models/media.dart';
import '../library/media_details.dart';
import '../library/media_poster.dart';
import 'home_hero.dart';

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final personalized = ref.watch(personalizedHomeFeedProvider).value;
    return feed.when(
      loading: () => const _HomeLoading(),
      error: (error, stack) =>
          _HomeFailure(onRetry: () => ref.invalidate(homeFeedProvider)),
      data: (data) {
        if (data.trending.isEmpty &&
            data.newReleases.isEmpty &&
            data.popular.isEmpty) {
          return const EmptyState(
            icon: Icons.movie_filter_outlined,
            message: 'Nothing is airing here yet',
          );
        }
        return CustomScrollView(
          key: const PageStorageKey('home-scroll'),
          slivers: [
            if (data.hero.isNotEmpty)
              SliverToBoxAdapter(
                child: HomeHero(
                  media: data.hero,
                  onDetails: (media) => showMediaDetails(context, media),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                ZeroTokens.space5,
                ZeroTokens.space6,
                ZeroTokens.space5,
                ZeroTokens.space7,
              ),
              sliver: SliverList.list(
                children: _withSectionSpacing([
                  if (personalized?.continueWatching.isNotEmpty ?? false)
                    _MediaRail(
                      title: 'Continue watching',
                      media: personalized!.continueWatching,
                    ),
                  if (personalized?.recommendations.isNotEmpty ?? false)
                    _MediaRail(
                      title: personalized!.favoriteGenres.isEmpty
                          ? 'For you'
                          : 'For you · ${personalized.favoriteGenres.join(' & ')}',
                      media: personalized.recommendations,
                      onTitleTap: personalized.favoriteGenres.isEmpty
                          ? null
                          : () => _openSearch(
                              context,
                              genre: personalized.favoriteGenres.first,
                              sort: 'score',
                            ),
                    ),
                  if (data.trending.isNotEmpty)
                    _MediaRail(
                      title: 'Trending this season',
                      media: data.trending,
                      onTitleTap: () => _openSearch(
                        context,
                        sort: 'trending',
                        season: _seasonName(DateTime.now()),
                        year: DateTime.now().year,
                      ),
                    ),
                  if (data.newReleases.isNotEmpty)
                    _MediaRail(
                      title: 'New & noteworthy',
                      media: data.newReleases,
                      onTitleTap: () => _openSearch(
                        context,
                        sort: 'popularity',
                        year: DateTime.now().year,
                      ),
                    ),
                  for (final section in data.genreSections)
                    _MediaRail(
                      title: '${section.genre} picks',
                      media: section.media,
                      onTitleTap: () => _openSearch(
                        context,
                        genre: section.genre,
                        sort: 'popularity',
                      ),
                    ),
                  if (data.popular.isNotEmpty)
                    _MediaRail(
                      title: 'All-time popular',
                      media: data.popular,
                      onTitleTap: () =>
                          _openSearch(context, sort: 'popularity'),
                    ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MediaRail extends StatelessWidget {
  const _MediaRail({required this.title, required this.media, this.onTitleTap});

  final String title;
  final List<Media> media;
  final VoidCallback? onTitleTap;

  @override
  Widget build(BuildContext context) {
    return TitledRail(
      title: title,
      onTitleTap: onTitleTap,
      children: [
        for (final item in media)
          MediaPoster(
            key: ValueKey(item.id),
            media: item,
            onTap: () => showMediaDetails(context, item),
          ),
      ],
    );
  }
}

List<Widget> _withSectionSpacing(List<Widget> sections) => [
  for (var index = 0; index < sections.length; index++) ...[
    if (index > 0) const SizedBox(height: ZeroTokens.space7),
    sections[index],
  ],
];

void _openSearch(
  BuildContext context, {
  String? genre,
  String? sort,
  String? season,
  int? year,
}) {
  context.go(
    Uri(
      path: '/search',
      queryParameters: {
        'genre': ?genre,
        'sort': ?sort,
        'season': ?season,
        if (year != null) 'year': '$year',
      },
    ).toString(),
  );
}

String _seasonName(DateTime date) => switch (date.month) {
  <= 3 => 'winter',
  <= 6 => 'spring',
  <= 9 => 'summer',
  _ => 'fall',
};

class _HomeLoading extends StatelessWidget {
  const _HomeLoading();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Skeleton(height: 307, borderRadius: 0),
        const SizedBox(height: ZeroTokens.space6),
        for (var rail = 0; rail < 2; rail++) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: ZeroTokens.space5),
            child: Skeleton(width: 180, height: 22),
          ),
          const SizedBox(height: ZeroTokens.space3),
          SizedBox(
            height: 286,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: ZeroTokens.space5,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: 7,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: ZeroTokens.space3),
              itemBuilder: (_, _) => const PosterSkeleton(),
            ),
          ),
          const SizedBox(height: ZeroTokens.space7),
        ],
      ],
    );
  }
}

class _HomeFailure extends StatelessWidget {
  const _HomeFailure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const EmptyState(
            icon: Icons.cloud_off_rounded,
            message: 'The library could not be loaded',
            detail:
                'Your cached library will appear again when it is available.',
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
