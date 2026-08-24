import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Shows a dialog with the app's soft-modal treatment (design-map §1.11/§1.13):
///
/// - Backdrop: vignette — `radial-gradient(ellipse, transparent 0%,
///   rgba(0,0,0,.85) 100%)` over `rgba(0,0,0,.65)`. **No backdrop blur**
///   (fragile on Linux).
/// - Dialog: scale .95→1 over `--motion-panel` (240ms), transform origin
///   bottom center, with a fade.
Future<T?> showSoftModal<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent, // the vignette is our own layer
    transitionDuration: ShiruTokens.motionPanel,
    pageBuilder: (context, animation, secondaryAnimation) =>
        builder(context),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final t = ShiruTokens.easeSettle.transform(animation.value);
      return Stack(
        children: [
          // Vignette backdrop, faded with the route animation.
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: t,
                child: const _VignetteBackdrop(),
              ),
            ),
          ),
          Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.95 + 0.05 * t,
              alignment: Alignment.bottomCenter,
              child: child,
            ),
          ),
        ],
      );
    },
  );
}

class _VignetteBackdrop extends StatelessWidget {
  const _VignetteBackdrop();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      // rgba(0,0,0,.65) base wash…
      decoration: BoxDecoration(color: Color(0xA6000000)),
      child: DecoratedBox(
        // …under an elliptical vignette to rgba(0,0,0,.85) at the edges.
        decoration: BoxDecoration(
          gradient: RadialGradient(
            radius: 1.0,
            colors: [Color(0x00000000), Color(0xD9000000)],
          ),
        ),
        child: SizedBox.expand(),
      ),
    );
  }
}

/// The soft-modal surface: near-black panel, hairline border, panel radius.
class SoftModal extends StatelessWidget {
  const SoftModal({
    super.key,
    required this.child,
    this.maxWidth = 400, // ~52rem
    this.padding = const EdgeInsets.all(ShiruTokens.space5),
  });

  final Widget child;
  final double maxWidth;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Material(
          type: MaterialType.transparency,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ShiruTokens.darkVeryDim,
              borderRadius: BorderRadius.circular(ShiruTokens.radiusPanel),
              border: Border.all(color: ShiruTokens.surfaceBorder),
              boxShadow: ShiruTokens.toastShadow,
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}
