import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'hover_region.dart';

enum AccentPillVariant {
  /// `hero-cta`: filled tertiary, white text, glow shadow.
  /// Hover: tertiary-light + scale 1.03.
  cta,

  /// `hero-alt`: ghost — white .09 bg, white .18 border.
  /// Hover: bg white .16.
  alt,
}

/// Hero action pill (design-map §1.9).
class AccentPill extends StatefulWidget {
  const AccentPill({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.variant = AccentPillVariant.cta,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final AccentPillVariant variant;

  @override
  State<AccentPill> createState() => _AccentPillState();
}

class _AccentPillState extends State<AccentPill> {
  static const _altBg = Color(0x17FFFFFF); // white .09
  static const _altBgHover = Color(0x29FFFFFF); // white .16
  static const _altBorder = Color(0x2EFFFFFF); // white .18

  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isCta = widget.variant == AccentPillVariant.cta;
    return HoverRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      builder: (context, hovered) {
        final scale = _pressed ? 0.99 : (isCta && hovered ? 1.03 : 1.0);
        return GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: scale,
            duration:
                _pressed ? ShiruTokens.motionPress : ShiruTokens.motion,
            curve:
                _pressed ? ShiruTokens.easePress : ShiruTokens.easeSettle,
            child: Stack(
              children: [
                // Pre-painted CTA glow, faded — never a transitioned shadow.
                if (isCta)
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(
                          Radius.circular(ShiruTokens.radiusPill),
                        ),
                        boxShadow: ShiruTokens.ctaGlow,
                      ),
                    ),
                  ),
                // Base skin.
                Positioned.fill(
                  child: _skin(
                    color: isCta ? ShiruTokens.accent : _altBg,
                    border: isCta ? null : _altBorder,
                  ),
                ),
                // Hover skin faded in on top (colors never tween).
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: ShiruTokens.motion,
                    curve: ShiruTokens.easeSettle,
                    child: _skin(
                      color:
                          isCta ? ShiruTokens.accentLight : _altBgHover,
                      border: isCta ? null : _altBorder,
                    ),
                  ),
                ),
                // The single content copy sizes the stack; the skins
                // stretch behind it.
                _content(),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _skin({required Color color, Color? border}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(ShiruTokens.radiusPill),
        border: border == null ? null : Border.all(color: border),
      ),
    );
  }

  Widget _content() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ShiruTokens.space4,
        vertical: ShiruTokens.space2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(
              widget.icon,
              size: ShiruTokens.fontScale16,
              color: ShiruTokens.highlight,
            ),
            const SizedBox(width: ShiruTokens.space1),
          ],
          Text(
            widget.label,
            style: const TextStyle(
              fontFamily: ShiruTokens.fontFamily,
              fontSize: ShiruTokens.fontScale14,
              fontWeight: FontWeight.w700,
              color: ShiruTokens.highlight,
            ),
          ),
        ],
      ),
    );
  }
}
