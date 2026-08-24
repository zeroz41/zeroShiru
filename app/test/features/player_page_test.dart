import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/application/playback/backend.dart';
import 'package:zeroshiru/application/playback/providers.dart';
import 'package:zeroshiru/application/playback/request.dart';
import 'package:zeroshiru/application/library/providers.dart';
import 'package:zeroshiru/application/settings/providers.dart';
import 'package:zeroshiru/domain/models/availability.dart';
import 'package:zeroshiru/domain/models/media.dart';
import 'package:zeroshiru/domain/models/settings.dart';
import 'package:zeroshiru/domain/models/torrent.dart';
import 'package:zeroshiru/domain/ports/ports.dart';
import 'package:zeroshiru/features/player/player_page.dart';
import 'package:zeroshiru/infrastructure/network/transport.dart';

class _FakeEngine implements MediaEngine {
  final states = StreamController<PlaybackSnapshot>.broadcast();
  final cues = StreamController<SubtitleCue>.broadcast();
  final secondCues = StreamController<SubtitleCue>.broadcast();
  final metricEvents = StreamController<PlayerMetrics>.broadcast();
  final calls = <String>[];

  @override
  Stream<PlaybackSnapshot> get state => states.stream;

  @override
  Stream<SubtitleCue> get primaryCues => cues.stream;

  @override
  Stream<SubtitleCue> get secondaryCues => secondCues.stream;

  @override
  Stream<PlayerMetrics> get metrics => metricEvents.stream;

  @override
  Future<void> open(
    PlayerFile source, {
    ResumePoint? resume,
    PlaybackPreferences? preferences,
  }) async {
    calls.add('open:${source.name}');
    states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.ready,
        duration: Duration(minutes: 24),
        volume: 0.8,
      ),
    );
  }

  @override
  Future<void> play() async {
    calls.add('play');
    states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        position: Duration(minutes: 2),
        duration: Duration(minutes: 24),
        buffered: Duration(minutes: 4),
        volume: 0.8,
      ),
    );
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async =>
      calls.add('seek:${position.inSeconds}');

  @override
  Future<void> setVolume(double volume) async => calls.add('volume:$volume');

  @override
  Future<void> setSpeed(double speed) async => calls.add('speed:$speed');

  @override
  Future<void> selectAudio(String? trackId) async =>
      calls.add('audio:$trackId');

  @override
  Future<void> selectSubtitle(
    String? trackId, {
    bool secondary = false,
  }) async => calls.add('subtitle:$trackId:$secondary');

  @override
  Future<void> setSubtitleRendering(SubtitleRendering mode) async =>
      calls.add('render:${mode.name}');

  @override
  Future<void> setSubtitleDelay(
    Duration delay, {
    bool secondary = false,
  }) async => calls.add('delay:${delay.inMilliseconds}:$secondary');

  @override
  Future<void> addSubtitle(
    String source, {
    String? title,
    String? language,
  }) async => calls.add('add-subtitle');

  @override
  Future<void> dispose() async {
    await states.close();
    await cues.close();
    await secondCues.close();
    await metricEvents.close();
  }
}

class _FakeBackend implements PlaybackBackend {
  _FakeBackend(this.engine);

  @override
  final _FakeEngine engine;

  @override
  Widget buildSurface({Key? key, BoxFit fit = BoxFit.contain}) => ColoredBox(
    key: key,
    color: Colors.black,
    child: Text('surface:${fit.name}'),
  );

  @override
  Future<void> dispose() => engine.dispose();
}

Widget _app(Widget page, _FakeBackend backend) => ProviderScope(
  overrides: [playbackBackendProvider.overrideWithValue(backend)],
  child: MaterialApp(theme: buildShiruTheme(), home: page),
);

void main() {
  testWidgets('player opens a supplied source and renders native controls', (
    tester,
  ) async {
    final engine = _FakeEngine();
    final backend = _FakeBackend(engine);
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv?token=do-not-render',
    );

    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), backend),
    );
    await tester.pump();
    await tester.pump();

    expect(engine.calls.take(2), ['open:Episode 03.mkv', 'play']);
    expect(find.text('Episode 03.mkv'), findsOneWidget);
    expect(find.textContaining('do-not-render'), findsNothing);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.text('2:00 / 24:00'), findsOneWidget);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    expect(engine.calls, contains('pause'));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(engine.calls, contains('seek:122'));
  });

  testWidgets('player without a resolved file stays in a calm empty state', (
    tester,
  ) async {
    final backend = _FakeBackend(_FakeEngine());
    await tester.pumpWidget(_app(const PlayerPage(), backend));

    expect(find.text('Choose an episode to play'), findsOneWidget);
    expect(find.byKey(const ValueKey('playback-surface')), findsOneWidget);
  });

  testWidgets('player exposes dual-language subtitle controls and timing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    final backend = _FakeBackend(engine);
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), backend),
    );
    await tester.pump();
    await tester.pump();

    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        duration: Duration(minutes: 24),
        subtitleTracks: [
          MediaTrack(
            id: 'sub-en',
            kind: TrackKind.subtitle,
            language: 'en',
            title: 'Full dialogue',
            codec: 'ass',
          ),
          MediaTrack(
            id: 'sub-ja',
            kind: TrackKind.subtitle,
            language: 'ja',
            codec: 'ass',
          ),
        ],
        selectedPrimarySubtitle: 'sub-en',
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Subtitles'));
    await tester.pumpAndSettle();
    expect(find.text('Subtitles & languages'), findsOneWidget);
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('Secondary'), findsOneWidget);
    expect(find.text('Japanese'), findsNWidgets(2));

    await tester.tap(find.text('Japanese').last);
    await tester.pump();
    expect(engine.calls, contains('subtitle:sub-ja:true'));

    await tester.tap(find.text('Learning'));
    await tester.pump();
    expect(engine.calls, contains('render:learning'));

    await tester.tap(find.byTooltip('Later by 0.1 seconds').first);
    await tester.pump();
    expect(engine.calls, contains('delay:100:false'));
  });

  testWidgets('learning mode displays current primary and secondary cues', (
    tester,
  ) async {
    final engine = _FakeEngine();
    final backend = _FakeBackend(engine);
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), backend),
    );
    await tester.pump();
    await tester.pump();

    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        position: Duration(seconds: 12),
        duration: Duration(minutes: 24),
        subtitleRendering: SubtitleRendering.learning,
      ),
    );
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-en',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: 'Primary dialogue',
      ),
    );
    engine.secondCues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: 'Secondary dialogue',
      ),
    );
    await tester.pump();

    expect(find.text('Primary dialogue'), findsOneWidget);
    expect(find.text('Secondary dialogue'), findsOneWidget);
  });

  testWidgets(
    'TorBox launch resolves the requested episode before opening mpv',
    (tester) async {
      final engine = _FakeEngine();
      final backend = _FakeBackend(engine);
      final debrid = _ResolvingDebrid();
      final probe = _ProbeTransport();
      final repository = _SettingsRepository(
        const Settings(debridService: DebridService.torbox),
      );
      final credentials = _Credentials()..value = 'torbox-secret';
      const launch = PlaybackLaunch(
        media: Media(
          id: 42,
          title: MediaTitle(userPreferred: 'Clean Player Show'),
          episodes: 12,
          coverImage: 'https://images.example/cover.jpg',
        ),
        episode: 7,
        magnet: '0123456789abcdef0123456789abcdef01234567',
        service: DebridService.torbox,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackBackendProvider.overrideWithValue(backend),
            playbackProbeTransportProvider.overrideWithValue(probe),
            settingsRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(credentials),
            debridClientsProvider.overrideWithValue({
              DebridService.torbox: debrid,
            }),
          ],
          child: MaterialApp(
            theme: buildShiruTheme(),
            home: const PlayerPage(initialLaunch: launch),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(debrid.calls, [('torbox-secret', launch.magnet, 7)]);
      expect(probe.requests.single.headers['range'], 'bytes=0-');
      expect(engine.calls.take(2), ['open:Show - 07.mkv', 'play']);
      expect(find.text('Clean Player Show'), findsOneWidget);
      expect(find.text('Episode 7'), findsOneWidget);
      expect(find.text('TorBox'), findsOneWidget);
      expect(find.textContaining('torbox-secret'), findsNothing);
      expect(find.textContaining('signed-token'), findsNothing);
    },
  );
}

class _SettingsRepository implements SettingsRepository {
  _SettingsRepository(this.settings);

  Settings settings;
  final changesController = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => changesController.stream;

  @override
  Settings readSettings() => settings;

  @override
  Future<void> writeSettings(Settings settings) async {
    this.settings = settings;
  }

  @override
  T read<T>(String key, T fallback) => fallback;

  @override
  Future<void> write<T>(String key, T value) async {}
}

class _Credentials implements CredentialStore {
  String? value;

  @override
  Future<String?> read(String key) async =>
      key == debridCredentialKey(DebridService.torbox) ? value : null;

  @override
  Future<void> write(String key, String value) async => this.value = value;

  @override
  Future<void> delete(String key) async => value = null;
}

class _ResolvingDebrid implements DebridClient {
  final calls = <(String, String, int?)>[];

  @override
  DebridService get service => DebridService.torbox;

  @override
  bool get checkAddsMagnets => false;

  @override
  Future<DebridAccount> validate(String apiKey) async =>
      const DebridAccount(username: 'test');

  @override
  Future<Map<String, Availability>> availability(
    String apiKey,
    List<String> hashes,
  ) async => const {};

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) async {
    calls.add((apiKey, magnet, episode));
    const target = PlayerFile(
      name: 'Show - 07.mkv',
      url: 'https://cdn.example/video.mkv?signed-token=hidden',
      infoHash: '0123456789abcdef0123456789abcdef01234567',
    );
    return const ResolvedDebrid(
      hash: '0123456789abcdef0123456789abcdef01234567',
      name: 'Show',
      files: [target],
      target: target,
    );
  }

  @override
  Future<void> forgetResolved(String apiKey, String hash) async {}
}

class _ProbeTransport implements StreamingTransport {
  final requests = <HttpRequest>[];

  @override
  Future<StreamedResponse> open(HttpRequest request) async {
    requests.add(request);
    return StreamedResponse(
      status: 206,
      body: Stream.value(List<int>.filled(262144, 0)),
      cancel: () {},
    );
  }
}
