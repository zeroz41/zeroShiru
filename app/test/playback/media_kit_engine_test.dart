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

    test('auto subtitles report the effective visible default track', () {
      const tracks = [
        kit.SubtitleTrack('2', 'Signs', 'eng'),
        kit.SubtitleTrack('3', 'Full dialogue', 'eng', isDefault: true),
      ];

      expect(selectedKitSubtitleTrackId('auto', tracks), '3');
      expect(selectedKitSubtitleTrackId('no', tracks), isNull);
      expect(selectedKitSubtitleTrackId('2', tracks), '2');
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

    test('prefers an exact region then falls back to the language family', () {
      const tracks = [
        kit.AudioTrack('1', 'European', 'pt-PT'),
        kit.AudioTrack('2', 'Brazilian', 'por_BR'),
      ];

      expect(
        preferredKitTrack(tracks, 'pt-BR', (track) => track.language)?.id,
        '2',
      );
      expect(
        preferredKitTrack(tracks, 'pt-AO', (track) => track.language)?.id,
        '1',
      );
      expect(
        preferredKitTrack(tracks, 'und', (track) => track.language),
        isNull,
      );
    });

    test('sidecar subtitles enforce both transport and format boundaries', () {
      expect(isAllowedSubtitleSource('file:///tmp/dialogue.ass'), isTrue);
      expect(
        isAllowedSubtitleSource('https://cdn.example/subtitle.vtt?sig=secret'),
        isTrue,
      );
      expect(
        isAllowedSubtitleSource('http://cdn.example/subtitle.srt'),
        isFalse,
      );
      expect(isAllowedSubtitleSource('file:///tmp/subtitle.exe'), isFalse);
    });

    test('turns formatted subtitle payloads into plain text', () {
      expect(plainSubtitleText(r'{\an8}<i>Hello</i>\Nworld'), 'Hello\nworld');
    });
  });
}
