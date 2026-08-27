import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/palette.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/poster_card.dart';
import '../../domain/models/media.dart';

class MediaPoster extends StatelessWidget {
  const MediaPoster({
    super.key,
    required this.media,
    required this.onTap,
    this.width = ZeroTokens.cardWidth,
  });

  final Media media;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) {
    final cover = media.coverImage;
    return PosterCard(
      title: media.title.display,
      image: cover == null ? null : CachedNetworkImageProvider(cover),
      bloomColor: parseMediaColor(media.coverColor),
      airing: media.status == MediaStatus.releasing,
      progress: _progress(media),
      metadata: _metadata(media, context.zeroPalette),
      width: width,
      onTap: onTap,
    );
  }
}

List<PosterCardMetadata> _metadata(Media media, ZeroPalette colors) {
  final identity = [
    if (media.seasonYear != null) '${media.seasonYear}',
    if (media.format != null && media.format != MediaFormat.unknown)
      _formatLabel(media.format!),
  ].join(' · ');
  return [
    if (media.listEntry case final entry?)
      if (entry.progress > 0)
        PosterCardMetadata(
          media.maxEpisode == null
              ? 'Episode ${entry.progress}'
              : 'Ep ${entry.progress} of ${media.maxEpisode}',
          icon: Icons.play_circle_outline_rounded,
          color: colors.accentSoft,
        ),
    if (media.listEntry?.progress == null || media.listEntry!.progress == 0)
      if (identity.isNotEmpty) PosterCardMetadata(identity),
    if (media.averageScore != null)
      PosterCardMetadata(
        '${media.averageScore}%',
        icon: Icons.star_rounded,
        color: colors.warning,
      ),
  ];
}

double? _progress(Media media) {
  final watched = media.listEntry?.progress;
  final total = media.maxEpisode;
  if (watched == null || watched <= 0 || total == null || total <= 0) {
    return null;
  }
  return (watched / total).clamp(0.0, 1.0);
}

String _formatLabel(MediaFormat format) => switch (format) {
  MediaFormat.tv => 'TV',
  MediaFormat.tvShort => 'TV Short',
  MediaFormat.movie => 'Movie',
  MediaFormat.special => 'Special',
  MediaFormat.ova => 'OVA',
  MediaFormat.ona => 'ONA',
  MediaFormat.music => 'Music',
  MediaFormat.unknown => '',
};

Color? parseMediaColor(String? value) {
  if (value == null) return null;
  final hex = value.trim().replaceFirst('#', '');
  if (hex.length != 6) return null;
  final number = int.tryParse(hex, radix: 16);
  return number == null ? null : Color(0xFF000000 | number);
}
