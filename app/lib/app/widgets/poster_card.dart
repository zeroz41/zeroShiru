import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'hover_region.dart';

/// The "soft poster" SmallCard (design-map §1.7).
///
/// - Container: aspect 152/296, padding, hairline border, panel gradient,
///   radius 9.6px, resting shadow.
/// - Artwork: aspect 230/331, cover fit, radius 6.9px.
/// - Hover (pointer devices only): rises 4px, accent border, lift shadow
///   layer faded in via opacity — the shadow itself is pre-painted, never
///   transitioned.
/// - Press: settles back down, shadow at .4 opacity.
/// - Focus: accent ring, offset.
/// - Airing: pulsing ring + green AIRING badge.
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.image,
    this.imageBuilder,
    this.onTap,
    this.bloomColor,
    this.airing = false,
    this.width = ShiruTokens.cardWidth,
  }) : assert(
          image == null || imageBuilder == null,
          'Provide image or imageBuilder, not both.',
        );

  final String title;

  /// Artwork provider; kept infrastructure-agnostic.
  final ImageProvider? image;

  /// Alternative to [image]: build the artwork widget yourself (it will be
  /// clipped and cover-fitted by the card).
  final WidgetBuilder? imageBuilder;

  final VoidCallback? onTap;

  /// Per-poster bloom, from AniList `coverImage.color`. Falls back to the
  /// UI accent.
  final Color? bloomColor;

  /// Shows the pulsing ring + green AIRING badge.
  final bool airing;

  final double width;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return HoverRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      builder: (context, hovered) {
        final lifted = hovered && !_pressed;
        return FocusableActionDetector(
          onFocusChange: (v) => setState(() => _focused = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: SizedBox(
              width: widget.width,
              child: AspectRatio(
                aspectRatio: ShiruTokens.cardAspect,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (widget.airing)
                      const Positioned.fill(
                        left: -10,
                        top: -10,
                        right: -10,
                        bottom: -10,
                        child: _AiringRing(),
                      ),
                    Positioned.fill(
                      child: AnimatedSlide(
                        // -.5rem rise expressed as a fraction of the
                        // card's own height (AnimatedSlide is relative).
                        offset: lifted
                            ? Offset(
                                0,
                                -ShiruTokens.cardHoverRise /
                                    (widget.width / ShiruTokens.cardAspect),
                              )
                            : Offset.zero,
                        duration: _pressed
                            ? ShiruTokens.motionPress
                            : ShiruTokens.motion,
                        curve: _pressed
                            ? ShiruTokens.easePress
                            : ShiruTokens.easeSettle,
                        child: _buildCard(context, hovered, lifted),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard(BuildContext context, bool hovered, bool lifted) {
    final showHoverSkin = hovered || _pressed;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Lift shadow layer: pre-painted, faded via opacity. 1.0 lifted,
        // .4 while pressed, 0 at rest.
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: lifted ? 1 : (_pressed && hovered ? 0.4 : 0),
            duration:
                _pressed ? ShiruTokens.motionPress : ShiruTokens.motion,
            curve: ShiruTokens.easeSettle,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius:
                    BorderRadius.circular(ShiruTokens.radiusCard),
                boxShadow: ShiruTokens.liftShadow(widget.bloomColor),
              ),
            ),
          ),
        ),
        // Resting card skin.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
              border: Border.all(color: ShiruTokens.surfaceBorder),
              gradient: const LinearGradient(
                begin: Alignment(-0.42, -1), // ~165deg
                end: Alignment(0.42, 1),
                colors: [
                  ShiruTokens.surfacePanel,
                  Color(0xB817191C), // hsla(220,10%,10%,.72)
                ],
              ),
              boxShadow: ShiruTokens.cardShadow,
            ),
          ),
        ),
        // Hover skin: accent border + darker bg, faded in (colors never
        // tween — the layer's opacity does).
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: showHoverSkin ? 1 : 0,
            duration:
                _pressed ? ShiruTokens.motionPress : ShiruTokens.motion,
            curve: ShiruTokens.easeSettle,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ShiruTokens.radiusCard),
                border: Border.all(color: ShiruTokens.cardHoverBorder),
                color: ShiruTokens.cardHoverBg,
              ),
            ),
          ),
        ),
        // Content.
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(ShiruTokens.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius:
                      BorderRadius.circular(ShiruTokens.radiusPosterArt),
                  child: AspectRatio(
                    aspectRatio: ShiruTokens.cardArtAspect,
                    child: _artwork(context),
                  ),
                ),
                const SizedBox(height: ShiruTokens.space1),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: ShiruTokens.fontFamily,
                      fontSize: ShiruTokens.fontScale14,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: ShiruTokens.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.airing)
          const Positioned(
            top: ShiruTokens.space1,
            right: ShiruTokens.space1,
            child: _AiringBadge(),
          ),
        // Focus ring.
        if (_focused)
          Positioned.fill(
            left: -ShiruTokens.focusRingOffset,
            top: -ShiruTokens.focusRingOffset,
            right: -ShiruTokens.focusRingOffset,
            bottom: -ShiruTokens.focusRingOffset,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    ShiruTokens.radiusCard + ShiruTokens.focusRingOffset,
                  ),
                  border: Border.all(
                    color: ShiruTokens.accent,
                    width: ShiruTokens.focusRingWidth,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _artwork(BuildContext context) {
    if (widget.imageBuilder != null) return widget.imageBuilder!(context);
    if (widget.image != null) {
      return Image(
        image: widget.image!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const ColoredBox(
          color: ShiruTokens.darkVeryLight,
        ),
      );
    }
    return const ColoredBox(color: ShiruTokens.darkVeryLight);
  }
}

/// Pulsing "airing" ring: 3.5s infinite, scale .955→1.01, opacity .9→0.
class _AiringRing extends StatefulWidget {
  const _AiringRing();

  @override
  State<_AiringRing> createState() => _AiringRingState();
}

class _AiringRingState extends State<_AiringRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3500),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = _controller.value;
          return Opacity(
            opacity: 0.9 * (1 - t),
            child: Transform.scale(
              scale: 0.955 + (1.01 - 0.955) * t,
              child: child,
            ),
          );
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(ShiruTokens.radiusCard + 10),
            border: Border.all(color: ShiruTokens.greenLight, width: 1.5),
          ),
        ),
      ),
    );
  }
}

class _AiringBadge extends StatelessWidget {
  const _AiringBadge();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ShiruTokens.green,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
      ),
      child: const Padding(
        // .35rem .9rem
        padding: EdgeInsets.symmetric(horizontal: 6.9, vertical: 2.7),
        child: Text(
          'AIRING',
          style: TextStyle(
            fontFamily: ShiruTokens.fontFamily,
            fontSize: ShiruTokens.remPx, // 1rem
            fontWeight: FontWeight.w700,
            color: ShiruTokens.highlight,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
