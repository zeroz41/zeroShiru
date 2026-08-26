import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../application/playback/backend.dart';
import '../../domain/ports/media_engine.dart';
import 'media_kit_engine.dart';

class MediaKitPlaybackBackend implements PlaybackBackend {
  MediaKitPlaybackBackend({PlaybackPreferences Function()? preferences})
    : _player = Player(
        configuration: const PlayerConfiguration(
          title: 'Zero',
          osc: false,
          libass: true,
          protocolWhitelist: ['file', 'tcp', 'tls', 'http', 'https', 'crypto'],
        ),
      ) {
    _engine = MediaKitEngine(_player, defaultPreferences: preferences);
    _video = VideoController(_player);
  }

  final Player _player;
  late final MediaKitEngine _engine;
  late final VideoController _video;

  @override
  MediaEngine get engine => _engine;

  @override
  Widget buildSurface({Key? key, BoxFit fit = BoxFit.contain}) => Video(
    key: key,
    controller: _video,
    fit: fit,
    controls: null,
    fill: const Color(0xFF000000),
  );

  @override
  Future<void> dispose() => _engine.dispose();
}
