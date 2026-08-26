import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Hover detection that only exists on pointer devices.
///
/// Design rule (design-map §5.5): hover states must not exist on touch.
/// [MouseRegion] enter events are filtered by device kind so stray
/// touch-generated enter events never flip the hovered state.
class HoverRegion extends StatefulWidget {
  const HoverRegion({
    super.key,
    required this.builder,
    this.cursor = MouseCursor.defer,
    this.onEnter,
    this.onExit,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final MouseCursor cursor;
  final VoidCallback? onEnter;
  final VoidCallback? onExit;

  @override
  State<HoverRegion> createState() => _HoverRegionState();
}

class _HoverRegionState extends State<HoverRegion> {
  bool _hovered = false;

  static bool _isPointerKind(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.mouse || kind == PointerDeviceKind.trackpad;

  void _set(bool value) {
    if (_hovered == value) return;
    setState(() => _hovered = value);
    (value ? widget.onEnter : widget.onExit)?.call();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.cursor,
      onEnter: (e) {
        if (_isPointerKind(e.kind)) _set(true);
      },
      onExit: (_) => _set(false),
      child: widget.builder(context, _hovered),
    );
  }
}
