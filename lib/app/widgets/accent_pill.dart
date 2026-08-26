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
            duration: _pressed ? ZeroTokens.motionPress : ZeroTokens.motion,
            curve: _pressed ? ZeroTokens.easePress : ZeroTokens.easeSettle,
            child: Stack(
              children: [
                // Pre-painted CTA glow, faded — never a transitioned shadow.
                if (isCta)
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.all(
                          Radius.circular(ZeroTokens.radiusPill),
                        ),
                        boxShadow: ZeroTokens.ctaGlow,
                      ),
                    ),
                  ),
                // Base skin.
                Positioned.fill(
                  child: _skin(
                    color: isCta ? ZeroTokens.accent : _altBg,
                    border: isCta ? null : _altBorder,
                  ),
                ),
                // Hover skin faded in on top (colors never tween).
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: ZeroTokens.motion,
                    curve: ZeroTokens.easeSettle,
                    child: _skin(
                      color: isCta ? ZeroTokens.accentLight : _altBgHover,
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
        borderRadius: BorderRadius.circular(ZeroTokens.radiusPill),
        border: border == null ? null : Border.all(color: border),
      ),
    );
  }

  Widget _content() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: ZeroTokens.space4,
        vertical: ZeroTokens.space2,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(
              widget.icon,
              size: ZeroTokens.fontScale16,
              color: ZeroTokens.highlight,
            ),
            const SizedBox(width: ZeroTokens.space1),
          ],
          Text(
            widget.label,
            style: const TextStyle(
              fontFamily: ZeroTokens.fontFamily,
              fontSize: ZeroTokens.fontScale14,
              fontWeight: FontWeight.w700,
              color: ZeroTokens.highlight,
            ),
          ),
        ],
      ),
    );
  }
}
