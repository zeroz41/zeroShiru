import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/soft_modal.dart';
import '../../domain/models/media.dart';

Future<void> showMediaDetails(BuildContext context, Media media) {
  return showSoftModal<void>(
    context: context,
    builder: (context) => SoftModal(
      maxWidth: 900,
      padding: EdgeInsets.zero,
      child: MediaDetails(media: media),
    ),
  );
}

class MediaDetails extends StatelessWidget {
  const MediaDetails({super.key, required this.media});

  final Media media;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: viewport.height * 0.86),
      child: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(ShiruTokens.space6),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 620;
                final body = _DetailsBody(media: media, compact: compact);
                return compact
                    ? body
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Cover(media: media, width: 210),
                          const SizedBox(width: ShiruTokens.space6),
                          Expanded(child: body),
                        ],
                      );
              },
            ),
          ),
          Positioned(
            top: ShiruTokens.space3,
            right: ShiruTokens.space3,
            child: IconButton.filledTonal(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailsBody extends StatelessWidget {
  const _DetailsBody({required this.media, required this.compact});

  final Media media;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (compact) ...[
          Center(child: _Cover(media: media, width: 170)),
          const SizedBox(height: ShiruTokens.space5),
        ],
        Padding(
          padding: const EdgeInsets.only(right: 44),
          child: Text(
            media.title.display,
            style: Theme.of(context).textTheme.displayMedium,
          ),
        ),
        const SizedBox(height: ShiruTokens.space3),
        Wrap(
          spacing: ShiruTokens.space2,
          runSpacing: ShiruTokens.space2,
          children: [
            if (media.format != null) _MetaChip(_format(media.format!)),
            if (media.episodes != null) _MetaChip('${media.episodes} episodes'),
            if (media.duration != null) _MetaChip('${media.duration} min'),
            if (media.averageScore != null)
              _MetaChip('${media.averageScore}% score'),
            if (media.season != null || media.seasonYear != null)
              _MetaChip(
                [
                  if (media.season != null) media.season!.name,
                  if (media.seasonYear != null) '${media.seasonYear}',
                ].join(' '),
              ),
          ],
        ),
        if (media.genres.isNotEmpty) ...[
          const SizedBox(height: ShiruTokens.space4),
          Wrap(
            spacing: ShiruTokens.space2,
            runSpacing: ShiruTokens.space2,
            children: [
              for (final genre in media.genres) Chip(label: Text(genre)),
            ],
          ),
        ],
        const SizedBox(height: ShiruTokens.space5),
        Text(
          _plainDescription(media.description),
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55),
        ),
        if (media.listEntry case final entry?) ...[
          const SizedBox(height: ShiruTokens.space5),
          Text(
            '${entry.status.name} · episode ${entry.progress}',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(color: ShiruTokens.accentVeryLight),
          ),
        ],
      ],
    );
  }

  static String _format(MediaFormat format) => switch (format) {
    MediaFormat.tv => 'TV',
    MediaFormat.tvShort => 'TV short',
    MediaFormat.movie => 'Movie',
    MediaFormat.special => 'Special',
    MediaFormat.ova => 'OVA',
    MediaFormat.ona => 'ONA',
    MediaFormat.music => 'Music',
    MediaFormat.unknown => 'Anime',
  };
}

class _Cover extends StatelessWidget {
  const _Cover({required this.media, required this.width});

  final Media media;
  final double width;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
      child: SizedBox(
        width: width,
        child: AspectRatio(
          aspectRatio: ShiruTokens.cardArtAspect,
          child: media.coverImage == null
              ? const ColoredBox(color: ShiruTokens.darkVeryLight)
              : Image(
                  image: CachedNetworkImageProvider(media.coverImage!),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: ShiruTokens.darkVeryLight),
                ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShiruTokens.surfaceHighlight,
        border: Border.all(color: ShiruTokens.surfaceBorder),
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ShiruTokens.space3,
          vertical: ShiruTokens.space1,
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
    );
  }
}

String _plainDescription(String? description) {
  if (description == null || description.trim().isEmpty) {
    return 'No synopsis is available yet.';
  }
  return description
      .replaceAll(RegExp('<br\\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp('<[^>]+>'), '')
      .trim();
}
