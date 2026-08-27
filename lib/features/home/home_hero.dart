import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../app/theme/palette.dart';
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
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _scheduleRotation();
  }

  @override
  void didUpdateWidget(covariant HomeHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.length != widget.media.length) {
      _index = 0;
      _scheduleRotation();
    }
  }

  void _scheduleRotation() {
    _rotation?.cancel();
    if (_hovered || widget.media.length < 2) return;
    _rotation = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_controller.hasClients) return;
      final next = (_index + 1) % widget.media.length;
      _goTo(next);
    });
  }

  void _goTo(int index) {
    if (!_controller.hasClients || widget.media.isEmpty) return;
    _controller.animateToPage(
      index % widget.media.length,
      duration: ZeroTokens.motionPanel,
      curve: ZeroTokens.easeSettle,
    );
  }

  void _onHover(bool hovered) {
    _hovered = hovered;
    if (hovered) {
      _rotation?.cancel();
    } else {
      _scheduleRotation();
    }
  }

  @override
  void dispose() {
    _rotation?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onHover(true),
      onExit: (_) => _onHover(false),
      child: SizedBox(
        height: 307,
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: widget.media.length,
              onPageChanged: (value) {
                setState(() => _index = value);
                _scheduleRotation();
              },
              itemBuilder: (context, index) => _HeroSlide(
                media: widget.media[index],
                onDetails: () => widget.onDetails(widget.media[index]),
              ),
            ),
            if (widget.media.length > 1) ...[
              Positioned(
                left: ZeroTokens.space3,
                top: 0,
                bottom: 0,
                child: _HeroArrow(
                  tooltip: 'Previous featured show',
                  icon: Icons.chevron_left_rounded,
                  onPressed: () => _goTo(
                    (_index - 1 + widget.media.length) % widget.media.length,
                  ),
                ),
              ),
              Positioned(
                right: ZeroTokens.space3,
                top: 0,
                bottom: 0,
                child: _HeroArrow(
                  tooltip: 'Next featured show',
                  icon: Icons.chevron_right_rounded,
                  onPressed: () => _goTo((_index + 1) % widget.media.length),
                ),
              ),
              Positioned(
                left: ZeroTokens.space7,
                bottom: ZeroTokens.space3,
                child: Row(
                  children: [
                    for (var i = 0; i < widget.media.length; i++)
                      Semantics(
                        button: true,
                        selected: i == _index,
                        label: 'Featured show ${i + 1}',
                        child: GestureDetector(
                          onTap: () => _goTo(i),
                          child: AnimatedContainer(
                            duration: ZeroTokens.motion,
                            curve: ZeroTokens.easeSettle,
                            width: i == _index ? 38 : 21,
                            height: 3,
                            margin: const EdgeInsets.only(
                              right: ZeroTokens.space1,
                            ),
                            decoration: BoxDecoration(
                              color: i == _index
                                  ? context.zeroPalette.accent
                                  : context.zeroPalette.textMuted,
                              borderRadius: BorderRadius.circular(
                                ZeroTokens.radiusPill,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeroArrow extends StatelessWidget {
  const _HeroArrow({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return Center(
      child: Material(
        color: colors.shell.withValues(alpha: 0.7),
        shape: CircleBorder(side: BorderSide(color: colors.border)),
        elevation: 6,
        shadowColor: Colors.black,
        child: IconButton(
          tooltip: tooltip,
          onPressed: onPressed,
          icon: Icon(icon, color: colors.text),
        ),
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
    final colors = context.zeroPalette;
    return ClipRRect(
      borderRadius: const BorderRadius.only(
        bottomLeft: Radius.circular(ZeroTokens.radiusSurfaceTop),
        bottomRight: Radius.circular(ZeroTokens.radiusSurfaceTop),
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
                  ColoredBox(color: colors.backgroundTop),
            )
          else
            ColoredBox(color: colors.backgroundTop),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  colors.background,
                  colors.background.withValues(alpha: 0.82),
                  colors.background.withValues(alpha: 0.45),
                  colors.background.withValues(alpha: 0),
                ],
                stops: [0, 0.42, 0.72, 1],
              ),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  colors.background,
                  colors.background.withValues(alpha: 0),
                ],
                stops: [0, 0.46],
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              return Padding(
                padding: const EdgeInsets.fromLTRB(
                  ZeroTokens.space7,
                  ZeroTokens.space5,
                  ZeroTokens.space7,
                  ZeroTokens.space7,
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
                                  42,
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
                        const SizedBox(height: ZeroTokens.space2),
                        Text(
                          _meta(media),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: colors.textSecondary),
                        ),
                        if (!narrow && media.description != null) ...[
                          const SizedBox(height: ZeroTokens.space2),
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
                        const SizedBox(height: ZeroTokens.space4),
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
