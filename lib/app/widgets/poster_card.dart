import 'package:flutter/material.dart';

import '../theme/palette.dart';
import '../theme/tokens.dart';
import 'hover_region.dart';

class PosterCardMetadata {
  const PosterCardMetadata(this.label, {this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;
}

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
/// - Airing: a quiet green status badge; no animated outlines between cards.
class PosterCard extends StatefulWidget {
  const PosterCard({
    super.key,
    required this.title,
    this.image,
    this.imageBuilder,
    this.onTap,
    this.bloomColor,
    this.airing = false,
    this.progress,
    this.metadata = const [],
    this.width = ZeroTokens.cardWidth,
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

  /// Optional watched fraction, painted over the artwork edge for quick
  /// resume scanning without adding another badge.
  final double? progress;

  /// Quiet, glanceable facts shown below the title. Keep this to two short
  /// items so poster rails remain easy to scan.
  final List<PosterCardMetadata> metadata;

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
                aspectRatio: ZeroTokens.cardAspect,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(
                      child: AnimatedSlide(
                        // -.5rem rise expressed as a fraction of the
                        // card's own height (AnimatedSlide is relative).
                        offset: lifted
                            ? Offset(
                                0,
                                -ZeroTokens.cardHoverRise /
                                    (widget.width / ZeroTokens.cardAspect),
                              )
                            : Offset.zero,
                        duration: _pressed
                            ? ZeroTokens.motionPress
                            : ZeroTokens.motion,
                        curve: _pressed
                            ? ZeroTokens.easePress
                            : ZeroTokens.easeSettle,
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
    final colors = context.zeroPalette;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Lift shadow layer: pre-painted, faded via opacity. 1.0 lifted,
        // .4 while pressed, 0 at rest.
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: lifted ? 1 : (_pressed && hovered ? 0.4 : 0),
            duration: _pressed ? ZeroTokens.motionPress : ZeroTokens.motion,
            curve: ZeroTokens.easeSettle,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
                boxShadow: colors.liftShadow(widget.bloomColor),
              ),
            ),
          ),
        ),
        // Resting card skin.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
              border: Border.all(color: colors.border),
              gradient: LinearGradient(
                begin: Alignment(-0.42, -1), // ~165deg
                end: Alignment(0.42, 1),
                colors: [
                  colors.panel,
                  colors.background.withValues(alpha: colors.panel.a),
                ],
              ),
              boxShadow: colors.cardShadow,
            ),
          ),
        ),
        // Hover skin: accent border + darker bg, faded in (colors never
        // tween — the layer's opacity does).
        Positioned.fill(
          child: AnimatedOpacity(
            opacity: showHoverSkin ? 1 : 0,
            duration: _pressed ? ZeroTokens.motionPress : ZeroTokens.motion,
            curve: ZeroTokens.easeSettle,
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ZeroTokens.radiusCard),
                border: Border.all(color: colors.cardHoverBorder),
                color: colors.cardHover,
              ),
            ),
          ),
        ),
        // Content.
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.all(ZeroTokens.cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(
                    ZeroTokens.radiusPosterArt,
                  ),
                  child: AspectRatio(
                    aspectRatio: ZeroTokens.cardArtAspect,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _artwork(context),
                        if (widget.progress case final progress?)
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              color: colors.accentHover,
                              backgroundColor: const Color(0x99000000),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: ZeroTokens.space1),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: ZeroTokens.fontFamily,
                      fontSize: ZeroTokens.fontScale14,
                      fontWeight: FontWeight.w700,
                      height: 1.2,
                      color: colors.text,
                    ),
                  ),
                ),
                if (widget.metadata.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  _MetadataRow(items: widget.metadata),
                ],
              ],
            ),
          ),
        ),
        if (widget.airing)
          const Positioned(
            top: ZeroTokens.space1,
            right: ZeroTokens.space1,
            child: _AiringBadge(),
          ),
        // Focus ring.
        if (_focused)
          Positioned.fill(
            left: -ZeroTokens.focusRingOffset,
            top: -ZeroTokens.focusRingOffset,
            right: -ZeroTokens.focusRingOffset,
            bottom: -ZeroTokens.focusRingOffset,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    ZeroTokens.radiusCard + ZeroTokens.focusRingOffset,
                  ),
                  border: Border.all(
                    color: colors.accent,
                    width: ZeroTokens.focusRingWidth,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _artwork(BuildContext context) {
    final colors = context.zeroPalette;
    if (widget.imageBuilder != null) return widget.imageBuilder!(context);
    if (widget.image != null) {
      return Image(
        image: widget.image!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => ColoredBox(color: colors.surfaceRaised),
      );
    }
    return ColoredBox(color: colors.surfaceRaised);
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.items});

  final List<PosterCardMetadata> items;

  @override
  Widget build(BuildContext context) {
    final visible = items.take(2).toList(growable: false);
    return SizedBox(
      height: 16,
      child: Row(
        children: [
          Expanded(child: _MetadataItem(item: visible.first)),
          if (visible.length > 1) ...[
            const SizedBox(width: ZeroTokens.space2),
            Flexible(child: _MetadataItem(item: visible.last)),
          ],
        ],
      ),
    );
  }
}

class _MetadataItem extends StatelessWidget {
  const _MetadataItem({required this.item});

  final PosterCardMetadata item;

  @override
  Widget build(BuildContext context) {
    final color = item.color ?? context.zeroPalette.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (item.icon != null) ...[
          Icon(item.icon, size: 12, color: color),
          const SizedBox(width: 3),
        ],
        Flexible(
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: ZeroTokens.fontFamilyStats,
              fontSize: ZeroTokens.fontSize12,
              fontWeight: FontWeight.w500,
              color: color,
              height: 1,
            ),
          ),
        ),
      ],
    );
  }
}

class _AiringBadge extends StatelessWidget {
  const _AiringBadge();

  @override
  Widget build(BuildContext context) {
    final colors = context.zeroPalette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.18),
        border: Border.all(color: colors.success.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.success,
                shape: BoxShape.circle,
              ),
              child: const SizedBox.square(dimension: 5),
            ),
            const SizedBox(width: 4),
            Text(
              'AIRING',
              style: TextStyle(
                fontFamily: ZeroTokens.fontFamily,
                fontSize: 8,
                fontWeight: FontWeight.w800,
                color: colors.text,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
