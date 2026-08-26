import 'package:flutter/widgets.dart';

import '../../domain/ports/media_engine.dart';

/// Owns one playback engine and the Flutter surface driven by that engine.
///
/// Keeping the surface behind this seam is important: feature widgets never
/// import media_kit, so a patched libmpv adapter or a TV-native player can be
/// substituted without changing the player screen.
abstract interface class PlaybackBackend {
  MediaEngine get engine;

  Widget buildSurface({Key? key, BoxFit fit = BoxFit.contain});

  Future<void> dispose();
}
