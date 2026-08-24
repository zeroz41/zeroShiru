import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/accent_pill.dart';
import '../../domain/models/media.dart';

class HomeHero extends StatefulWidget {
  const HomeHero({super.key, required this.media, required this.onDetails});

  final List<Media> media;
  final ValueChanged<Media> onDetails;

  @override
  State<HomeHero> createState() => _HomeHeroState();
}

class _HomeHeroState extends State<HomeHero> {
  final PageController _controller = PageController();
  Timer? _rotation;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _restartRotation();
  }

  @override
  void didUpdateWidget(covariant HomeHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.length != widget.media.length) {
      _index = 0;
      _restartRotation();
    }
  }

  void _restartRotation() {
    _rotation?.cancel();
    if (widget.media.length < 2) return;
    _rotation = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted || !_controller.hasClients) return;
      final next = (_index + 1) % widget.media.length;
      _controller.animateToPage(
        next,
        duration: ShiruTokens.motionPanel,
        curve: ShiruTokens.easeSettle,
      );
    });
  }

  @override
  void dispose() {
    _rotation?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 307,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: widget.media.length,
            onPageChanged: (value) => setState(() => _index = value),
            itemBuilder: (context, index) => _HeroSlide(
              media: widget.media[index],
              onDetails: () => widget.onDetails(widget.media[index]),
            ),
          ),
          if (widget.media.length > 1)
            Positioned(
              left: ShiruTokens.space7,
              bottom: ShiruTokens.space3,
              child: Row(
                children: [
                  for (var i = 0; i < widget.media.length; i++)
                    GestureDetector(
                      onTap: () => _controller.animateToPage(
                        i,
                        duration: ShiruTokens.motionPanel,
                        curve: ShiruTokens.easeSettle,
                      ),
                      child: AnimatedContainer(
                        duration: ShiruTokens.motion,
                        curve: ShiruTokens.easeSettle,
                        width: i == _index ? 38 : 21,
                        height: 3,
                        margin: const EdgeInsets.only(
                          right: ShiruTokens.space1,
                        ),
                        decoration: BoxDecoration(
                          color: i == _index
                              ? ShiruTokens.accent
                              : ShiruTokens.textMuted,
                          borderRadius: BorderRadius.circular(
                            ShiruTokens.radiusPill,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _HeroSlide extends StatelessWidget {
  const _HeroSlide({required this.media, required this.onDetails});

  final Media media;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final image = media.bannerImage ?? media.coverImage;
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(ShiruTokens.radiusSurfaceTop),
        bottomRight: Radius.circular(ShiruTokens.radiusSurfaceTop),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null)
            Image(
              image: CachedNetworkImageProvider(image),
              fit: BoxFit.cover,
              alignment: Alignment.centerRight,
              errorBuilder: (_, _, _) =>
                  const ColoredBox(color: ShiruTokens.darkDim),
            )
          else
            const ColoredBox(color: ShiruTokens.darkDim),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  ShiruTokens.dark,
                  Color(0xD117191C),
                  Color(0x7317191C),
                  Color(0x0017191C),
                ],
                stops: [0, 0.42, 0.72, 1],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [ShiruTokens.dark, Color(0x0017191C)],
                stops: [0, 0.46],
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  ShiruTokens.space7,
                  ShiruTokens.space5,
                  ShiruTokens.space7,
                  ShiruTokens.space7,
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: narrow ? constraints.maxWidth * 0.86 : 580,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          media.title.display,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.displayLarge
                              ?.copyWith(
                                fontSize: (constraints.maxWidth * 0.045).clamp(
                                  25,
                                  49,
                                ),
                                shadows: const [
                                  Shadow(
                                    color: Color(0x8C000000),
                                    offset: Offset(0, 2),
                                    blurRadius: 18,
                                  ),
                                ],
                              ),
                        ),
                        const SizedBox(height: ShiruTokens.space2),
                        Text(
                          _meta(media),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: ShiruTokens.textLight),
                        ),
                        if (!narrow && media.description != null) ...[
                          const SizedBox(height: ShiruTokens.space2),
                          Text(
                            media.description!.replaceAll(
                              RegExp('<[^>]+>'),
                              '',
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(height: 1.4),
                          ),
                        ],
                        const SizedBox(height: ShiruTokens.space4),
                        AccentPill(
                          label: 'View details',
                          icon: Icons.info_outline_rounded,
                          onTap: onDetails,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static String _meta(Media media) => [
    if (media.format != null) media.format!.name.toUpperCase(),
    if (media.episodes != null) '${media.episodes} episodes',
    if (media.averageScore != null) '${media.averageScore}% score',
    if (media.season != null || media.seasonYear != null)
      '${media.season?.name ?? ''} ${media.seasonYear ?? ''}'.trim(),
  ].join('  •  ');
}
