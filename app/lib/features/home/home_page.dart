import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    return feed.when(
      loading: () => const _HomeLoading(),
      error: (error, stack) =>
          _HomeFailure(onRetry: () => ref.invalidate(homeFeedProvider)),
      data: (data) {
        if (data.trending.isEmpty && data.popular.isEmpty) {
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
                ShiruTokens.space5,
                ShiruTokens.space6,
                ShiruTokens.space5,
                ShiruTokens.space7,
              ),
              sliver: SliverList.list(
                children: [
                  if (data.trending.isNotEmpty)
                    _MediaRail(
                      title: 'Trending this season',
                      media: data.trending,
                    ),
                  if (data.trending.isNotEmpty && data.popular.isNotEmpty)
                    const SizedBox(height: ShiruTokens.space7),
                  if (data.popular.isNotEmpty)
                    _MediaRail(title: 'All-time popular', media: data.popular),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MediaRail extends StatelessWidget {
  const _MediaRail({required this.title, required this.media});

  final String title;
  final List<Media> media;

  @override
  Widget build(BuildContext context) {
    return TitledRail(
      title: title,
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

class _HomeLoading extends StatelessWidget {
  const _HomeLoading();

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const Skeleton(height: 307, borderRadius: 0),
        const SizedBox(height: ShiruTokens.space6),
        for (var rail = 0; rail < 2; rail++) ...[
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: ShiruTokens.space5),
            child: Skeleton(width: 180, height: 22),
          ),
          const SizedBox(height: ShiruTokens.space3),
          SizedBox(
            height: 286,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(
                horizontal: ShiruTokens.space5,
              ),
              scrollDirection: Axis.horizontal,
              itemCount: 7,
              separatorBuilder: (_, _) =>
                  const SizedBox(width: ShiruTokens.space3),
              itemBuilder: (_, _) => const PosterSkeleton(),
            ),
          ),
          const SizedBox(height: ShiruTokens.space7),
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
