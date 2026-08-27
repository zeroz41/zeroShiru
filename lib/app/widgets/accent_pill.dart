import 'package:flutter/material.dart';

import '../theme/palette.dart';
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
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final isCta = widget.variant == AccentPillVariant.cta;
    final colors = context.zeroPalette;
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
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(ZeroTokens.radiusPill),
                        ),
                        boxShadow: colors.ctaGlow,
                      ),
                    ),
                  ),
                // Base skin.
                Positioned.fill(
                  child: _skin(
                    color: isCta ? colors.accent : colors.navHover,
                    border: isCta ? null : colors.border,
                  ),
                ),
                // Hover skin faded in on top (colors never tween).
                Positioned.fill(
                  child: AnimatedOpacity(
                    opacity: hovered ? 1 : 0,
                    duration: ZeroTokens.motion,
                    curve: ZeroTokens.easeSettle,
                    child: _skin(
                      color: isCta ? colors.accentHover : colors.navPress,
                      border: isCta ? null : colors.border,
                    ),
                  ),
                ),
                // The single content copy sizes the stack; the skins
                // stretch behind it.
                _content(colors),
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

  Widget _content(ZeroPalette colors) {
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
              color: widget.variant == AccentPillVariant.cta
                  ? colors.onAccent
                  : colors.text,
            ),
            const SizedBox(width: ZeroTokens.space1),
          ],
          Text(
            widget.label,
            style: TextStyle(
              fontFamily: ZeroTokens.fontFamily,
              fontSize: ZeroTokens.fontScale14,
              fontWeight: FontWeight.w700,
              color: widget.variant == AccentPillVariant.cta
                  ? colors.onAccent
                  : colors.text,
            ),
          ),
        ],
      ),
    );
  }
}
