import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' as kit;
import 'package:zero/domain/ports/media_engine.dart';
import 'package:zero/infrastructure/media/media_kit_engine.dart';

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

    test('resolves a newly loaded sidecar to its stable native track id', () {
      const tracks = kit.Tracks(
        subtitle: [
          kit.SubtitleTrack('2', 'English', 'eng'),
          kit.SubtitleTrack('7', 'Japanese · Jimaku · Naruto 003', 'jpn'),
        ],
      );

      final loaded = loadedExternalKitSubtitleTrack(
        tracks,
        previousTrackIds: const {'2'},
        title: 'Japanese · Jimaku · Naruto 003',
        language: 'ja',
      );

      expect(loaded?.id, '7');
    });
  });

  group('player boundary rules', () {
    test('a seek is not settled while the playhead is still at its origin', () {
      expect(
        seekTargetReached(
          origin: const Duration(seconds: 30),
          target: const Duration(minutes: 6),
          current: const Duration(seconds: 30),
        ),
        isFalse,
      );
      expect(
        seekTargetReached(
          origin: const Duration(seconds: 30),
          target: const Duration(minutes: 6),
          current: const Duration(minutes: 6),
        ),
        isTrue,
      );
      expect(
        seekTargetReached(
          origin: const Duration(minutes: 10),
          target: const Duration(minutes: 6),
          current: const Duration(minutes: 6),
        ),
        isTrue,
      );
    });

    test('seek refresh rejects mixed subtitle text and timing snapshots', () {
      const position = Duration(minutes: 6, seconds: 9);

      expect(
        nativeSubtitleSampleIsCurrent(
          const NativeSubtitleSample(
            textBefore: 'old Japanese line',
            textAfter: 'new Japanese line',
            startSeconds: 368,
            endSeconds: 372,
          ),
          position: position,
        ),
        isFalse,
      );
      expect(
        nativeSubtitleSampleIsCurrent(
          const NativeSubtitleSample(
            textBefore: 'old Japanese line',
            textAfter: 'old Japanese line',
            startSeconds: 20,
            endSeconds: 24,
          ),
          position: position,
        ),
        isFalse,
      );
      expect(
        nativeSubtitleSampleIsCurrent(
          const NativeSubtitleSample(
            textBefore: 'current Japanese line',
            textAfter: 'current Japanese line',
            startSeconds: 368,
            endSeconds: 372,
          ),
          position: position,
        ),
        isTrue,
      );
    });

    test(
      'track-transition backend logs are not promoted to media failures',
      () {
        final now = DateTime.utc(2026, 8, 25, 12);

        expect(
          shouldFailPlaybackForBackendError(
            phase: PlaybackPhase.playing,
            recoverableThrough: now.add(const Duration(seconds: 1)),
            now: now,
          ),
          isFalse,
        );
        expect(
          shouldFailPlaybackForBackendError(
            phase: PlaybackPhase.playing,
            recoverableThrough: now.subtract(const Duration(milliseconds: 1)),
            now: now,
          ),
          isTrue,
        );
        expect(
          shouldFailPlaybackForBackendError(
            phase: PlaybackPhase.opening,
            recoverableThrough: null,
            now: now,
          ),
          isTrue,
        );
      },
    );

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
      expect(normalizeTrackLanguage('jp'), 'ja');
      expect(normalizeTrackLanguage('English'), 'en');
      expect(normalizeTrackLanguage('pt_br'), 'pt-BR');
      expect(normalizeTrackLanguage('und'), isNull);
      expect(normalizeTrackLanguage(null), isNull);
    });

    test('only a concrete subtitle language is an explicit preference', () {
      expect(hasExplicitTrackLanguagePreference('eng'), isTrue);
      expect(hasExplicitTrackLanguagePreference('es-MX'), isTrue);
      expect(hasExplicitTrackLanguagePreference('und'), isFalse);
      expect(hasExplicitTrackLanguagePreference(null), isFalse);
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

    test('first-run defaults infer titles and avoid signs or commentary', () {
      const subtitles = [
        kit.SubtitleTrack('1', 'English Signs & Songs', null, isDefault: true),
        kit.SubtitleTrack('2', 'English Full Dialogue', null),
      ];
      const audio = [
        kit.AudioTrack('3', 'Japanese Commentary', null, isDefault: true),
        kit.AudioTrack('4', 'Japanese Original', null),
      ];

      expect(
        preferredKitTrack(
          subtitles,
          'eng',
          (track) => inferredTrackLanguage(track.language, track.title),
          scoreOf: (track) => automaticTrackScore(
            title: track.title,
            isDefault: track.isDefault ?? false,
            subtitle: true,
          ),
        )?.id,
        '2',
      );
      expect(
        preferredKitTrack(
          audio,
          'jpn',
          (track) => inferredTrackLanguage(track.language, track.title),
          scoreOf: (track) => automaticTrackScore(
            title: track.title,
            isDefault: track.isDefault ?? false,
          ),
        )?.id,
        '4',
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

    test('verifies the native secondary subtitle selection exactly', () {
      expect(nativeTrackSelectionMatches('7', '7'), isTrue);
      expect(nativeTrackSelectionMatches('8', '7'), isFalse);
      expect(nativeTrackSelectionMatches('no', null), isTrue);
      expect(nativeTrackSelectionMatches('7', null), isFalse);
    });
  });
}
