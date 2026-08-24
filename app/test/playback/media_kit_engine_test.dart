import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as kit;
import 'package:zeroshiru/domain/ports/media_engine.dart';
import 'package:zeroshiru/infrastructure/media/media_kit_engine.dart';

void main() {
  group('media_kit state mapping', () {
    test('maps normalized controls, dimensions, and real tracks', () {
      const audio = kit.AudioTrack(
        '2',
        'Japanese',
        'jpn',
        codec: 'aac',
        isDefault: true,
      );
      const subtitle = kit.SubtitleTrack(
        '4',
        'English signs',
        'eng_US',
        codec: 'hdmv_pgs_subtitle',
      );
      const state = kit.PlayerState(
        playing: true,
        position: Duration(minutes: 3),
        duration: Duration(minutes: 24),
        buffer: Duration(minutes: 5),
        volume: 125,
        rate: 1.25,
        width: 1920,
        height: 1080,
        tracks: kit.Tracks(audio: [audio], subtitle: [subtitle]),
        track: kit.Track(audio: audio, subtitle: subtitle),
      );

      final mapped = mapMediaKitState(
        state,
        generation: 7,
        phase: PlaybackPhase.ready,
        selectedSecondary: '5',
      );

      expect(mapped.generation, 7);
      expect(mapped.phase, PlaybackPhase.playing);
      expect(mapped.volume, 1.25);
      expect(mapped.speed, 1.25);
      expect((mapped.videoWidth, mapped.videoHeight), (1920, 1080));
      expect(mapped.audioTracks.single.language, 'ja');
      expect(mapped.audioTracks.single.languageOriginal, 'jpn');
      expect(mapped.audioTracks.single.isDefault, isTrue);
      expect(mapped.subtitleTracks.single.language, 'en-US');
      expect(mapped.subtitleTracks.single.isBitmapSubtitle, isTrue);
      expect(mapped.selectedAudio, '2');
      expect(mapped.selectedPrimarySubtitle, '4');
      expect(mapped.selectedSecondarySubtitle, '5');
    });

    test('buffering and completion take precedence over the command phase', () {
      expect(
        mapMediaKitState(
          const kit.PlayerState(buffering: true),
          generation: 1,
          phase: PlaybackPhase.paused,
        ).phase,
        PlaybackPhase.buffering,
      );
      expect(
        mapMediaKitState(
          const kit.PlayerState(completed: true, buffering: true),
          generation: 1,
          phase: PlaybackPhase.playing,
        ).phase,
        PlaybackPhase.ended,
      );
    });
  });

  group('player boundary rules', () {
    test('only HTTPS, files, and HTTP loopback enter libmpv', () {
      expect(
        isAllowedPlaybackSource('https://cdn.example/video.mkv?t=secret'),
        isTrue,
      );
      expect(isAllowedPlaybackSource('file:///tmp/video.mkv'), isTrue);
      expect(
        isAllowedPlaybackSource('http://127.0.0.1:4321/v1/stream/a'),
        isTrue,
      );
      expect(isAllowedPlaybackSource('http://[::1]:4321/v1/stream/a'), isTrue);
      expect(isAllowedPlaybackSource('http://cdn.example/video.mkv'), isFalse);
      expect(isAllowedPlaybackSource('ftp://cdn.example/video.mkv'), isFalse);
      expect(isAllowedPlaybackSource('/tmp/video.mkv'), isFalse);
    });

    test('normalizes tags without inventing unknown languages', () {
      expect(normalizeTrackLanguage('jpn'), 'ja');
      expect(normalizeTrackLanguage('pt_br'), 'pt-BR');
      expect(normalizeTrackLanguage('und'), isNull);
      expect(normalizeTrackLanguage(null), isNull);
    });

    test('turns formatted subtitle payloads into plain text', () {
      expect(plainSubtitleText(r'{\an8}<i>Hello</i>\Nworld'), 'Hello\nworld');
    });
  });
}
