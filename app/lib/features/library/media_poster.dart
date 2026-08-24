import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/poster_card.dart';
import '../../domain/models/media.dart';

class MediaPoster extends StatelessWidget {
  const MediaPoster({
    super.key,
    required this.media,
    required this.onTap,
    this.width = ShiruTokens.cardWidth,
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
      metadata: _metadata(media),
      width: width,
      onTap: onTap,
    );
  }
}

List<PosterCardMetadata> _metadata(Media media) {
  final identity = [
    if (media.seasonYear != null) '${media.seasonYear}',
    if (media.format != null && media.format != MediaFormat.unknown)
      _formatLabel(media.format!),
  ].join(' · ');
  return [
    if (identity.isNotEmpty) PosterCardMetadata(identity),
    if (media.averageScore != null)
      PosterCardMetadata(
        '${media.averageScore}%',
        icon: Icons.star_rounded,
        color: ShiruTokens.warning,
      ),
  ];
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
