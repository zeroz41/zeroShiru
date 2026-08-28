import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/network_image.dart';
import '../../app/widgets/poster_card.dart';
import '../../application/library/home_feed.dart';
import '../../application/library/providers.dart';
import '../../domain/models/media.dart';
import 'media_details.dart';
import 'media_poster.dart';

/// A landscape Continue Watching card: the next episode's thumbnail with the
/// in-episode watched fraction painted along its bottom edge, so the rail
/// reads as "resume here" rather than another poster wall.
class ContinueWatchingCard extends ConsumerWidget {
  const ContinueWatchingCard({super.key, required this.item, this.width = 300});

  final ContinueWatchingItem item;
  final double width;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final media = item.media;
    final colors = context.zeroPalette;
    // Episode art arrives late and optionally; the banner keeps the card
    // landscape in the meantime instead of stretching a portrait cover.
    final episodes = ref.watch(episodeMetadataProvider(media)).value;
    final episodeArt = episodes
        ?.where((info) => info.number == item.episode)
        .firstOrNull
        ?.imageUrl;
    final artwork = episodeArt ?? media.bannerImage ?? media.coverImage;
    final seriesProgress = _seriesProgress(media);
    return PosterCard(
      title: media.title.display,
      width: width,
      aspect: 300 / 228,
      artAspect: 16 / 9,
      bloomColor: parseMediaColor(media.coverColor),
      airing: media.status == MediaStatus.releasing,
      progress: item.resumeProgress ?? seriesProgress,
      imageBuilder: (context) => _EpisodeArtwork(
        url: artwork,
        logicalWidth: width,
        episode: item.episode,
      ),
      metadata: [
        PosterCardMetadata(
          media.maxEpisode == null
              ? 'Ep ${item.episode}'
              : 'Ep ${item.episode} of ${media.maxEpisode}',
          icon: Icons.play_circle_outline_rounded,
          color: colors.accentSoft,
        ),
        if (item.resumeProgress case final fraction?)
          PosterCardMetadata('${(fraction * 100).round()}% watched'),
      ],
      onTap: () =>
          showMediaDetails(context, media, initialEpisode: item.episode),
    );
  }

  double? _seriesProgress(Media media) {
    final watched = media.listEntry?.progress;
    final total = media.maxEpisode;
    if (watched == null || watched <= 0 || total == null || total <= 0) {
      return null;
    }
    return (watched / total).clamp(0.0, 1.0);
  }
}

class _EpisodeArtwork extends StatelessWidget {
  const _EpisodeArtwork({
    required this.url,
    required this.logicalWidth,
    required this.episode,
  });

  final String? url;
  final double logicalWidth;
  final int episode;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (url case final url?)
          Image(
            image: sizedNetworkImage(context, url, logicalWidth: logicalWidth),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => ColoredBox(color: colors.surfaceRaised),
          )
        else
          ColoredBox(color: colors.surfaceRaised),
        // Scrim keeps the episode pill readable over bright thumbnails.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.center,
              end: Alignment.bottomCenter,
              colors: [Color(0x00000000), Color(0xB3000000)],
            ),
          ),
        ),
        Positioned(
          left: ZeroTokens.space2,
          bottom: ZeroTokens.space2,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xB3000000),
              border: Border.all(color: colors.border),
              borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Text(
                'EP $episode',
                style: TextStyle(
                  fontFamily: ZeroTokens.fontFamily,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: colors.text,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
