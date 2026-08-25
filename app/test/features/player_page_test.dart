import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/application/playback/backend.dart';
import 'package:zeroshiru/application/playback/providers.dart';
import 'package:zeroshiru/application/playback/request.dart';
import 'package:zeroshiru/application/library/providers.dart';
import 'package:zeroshiru/application/learning/providers.dart';
import 'package:zeroshiru/application/learning/subtitle_providers.dart';
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
  String? addedSubtitleSource;
  String? addedSubtitleTitle;
  String? addedSubtitleLanguage;

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
  }) async {
    calls.add('add-subtitle');
    addedSubtitleSource = source;
    addedSubtitleTitle = title;
    addedSubtitleLanguage = language;
  }

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
  overrides: [
    playbackBackendProvider.overrideWithValue(backend),
    settingsRepositoryProvider.overrideWithValue(
      _SettingsRepository(const Settings()),
    ),
    credentialStoreProvider.overrideWithValue(_Credentials()),
    languageLearningToolsProvider.overrideWithValue(_FakeLearningTools()),
  ],
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

  testWidgets('clicking the video surface toggles playback', (tester) async {
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

    await tester.tap(find.byKey(const ValueKey('player-surface-interaction')));
    await tester.pump();

    expect(engine.calls.where((call) => call == 'pause'), hasLength(1));
  });

  testWidgets('closing the player pauses once and returns to its origin', (
    tester,
  ) async {
    final engine = _FakeEngine();
    final backend = _FakeBackend(engine);
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    final router = GoRouter(
      initialLocation: '/library',
      routes: [
        GoRoute(
          path: '/library',
          builder: (context, _) => Scaffold(
            body: FilledButton(
              onPressed: () => context.push('/player'),
              child: const Text('Open player'),
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, _) => const PlayerPage(initialSource: source),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackBackendProvider.overrideWithValue(backend),
          settingsRepositoryProvider.overrideWithValue(
            _SettingsRepository(const Settings()),
          ),
          credentialStoreProvider.overrideWithValue(_Credentials()),
          languageLearningToolsProvider.overrideWithValue(_FakeLearningTools()),
        ],
        child: MaterialApp.router(
          theme: buildShiruTheme(),
          routerConfig: router,
        ),
      ),
    );

    await tester.tap(find.text('Open player'));
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('Close player'), findsOneWidget);

    await tester.tap(find.byTooltip('Close player'));
    await tester.pumpAndSettle();

    expect(find.text('Open player'), findsOneWidget);
    expect(engine.calls.where((call) => call == 'pause'), hasLength(1));
  });

  testWidgets('episode back returns the active episode to its selector', (
    tester,
  ) async {
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
        title: MediaTitle(userPreferred: 'Selector Return Show'),
        episodes: 12,
      ),
      episode: 7,
      magnet: '0123456789abcdef0123456789abcdef01234567',
      service: DebridService.torbox,
    );
    int? returnedEpisode;
    final router = GoRouter(
      initialLocation: '/library',
      routes: [
        GoRoute(
          path: '/library',
          builder: (context, _) => Scaffold(
            body: FilledButton(
              onPressed: () async {
                returnedEpisode = await context.push<int>(
                  '/player',
                  extra: launch,
                );
              },
              child: const Text('Choose episode'),
            ),
          ),
        ),
        GoRoute(
          path: '/player',
          builder: (_, state) =>
              PlayerPage(initialLaunch: state.extra! as PlaybackLaunch),
        ),
      ],
    );
    addTearDown(router.dispose);
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
        child: MaterialApp.router(
          theme: buildShiruTheme(),
          routerConfig: router,
        ),
      ),
    );

    await tester.tap(find.text('Choose episode'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byTooltip('Back to episodes'));
    await tester.pumpAndSettle();

    expect(returnedEpisode, 7);
    expect(find.text('Choose episode'), findsOneWidget);
  });

  testWidgets('player chrome hides after inactivity and returns on movement', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final backend = _FakeBackend(_FakeEngine());
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), backend),
    );
    await tester.pump();
    await tester.pump();

    AnimatedOpacity bottomChrome() => tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('player-chrome-bottom')),
    );

    expect(bottomChrome().opacity, 1);
    await tester.pump(const Duration(milliseconds: 2700));
    await tester.pump(const Duration(milliseconds: 200));
    expect(bottomChrome().opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(500, 350));
    await mouse.moveTo(const Offset(502, 350));
    await tester.pump();
    expect(bottomChrome().opacity, 1);
    await mouse.removePointer();
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
        audioTracks: [
          MediaTrack(id: 'audio-en', kind: TrackKind.audio, language: 'en'),
          MediaTrack(id: 'audio-ja', kind: TrackKind.audio, language: 'ja'),
        ],
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
        selectedAudio: 'audio-en',
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
    expect(engine.calls, contains('audio:audio-ja'));
    expect(engine.calls, contains('subtitle:sub-ja:false'));
    expect(engine.calls, contains('subtitle:sub-en:true'));

    await tester.tap(find.byTooltip('Later by 0.1 seconds').first);
    await tester.pump();
    expect(engine.calls, contains('delay:100:false'));

    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.text('Subtitles & languages'), findsNothing);
  });

  testWidgets('learning mode renders native tokens and local definitions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 320);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

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
        subtitleTracks: [
          MediaTrack(id: 'sub-ja', kind: TrackKind.subtitle, language: 'ja'),
          MediaTrack(id: 'sub-en', kind: TrackKind.subtitle, language: 'en'),
        ],
        selectedPrimarySubtitle: 'sub-ja',
        selectedSecondarySubtitle: 'sub-en',
      ),
    );
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: '日本語を勉強する',
      ),
    );
    engine.secondCues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-en',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: 'Study Japanese',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('にほんご'), findsOneWidget);
    expect(find.text('Study Japanese'), findsOneWidget);

    await tester.tap(find.text('日本語'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Japanese language'), findsOneWidget);
  });

  testWidgets(
    'Learning automatically attaches the episode Japanese track and pairs English',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = _FakeEngine();
      final backend = _FakeBackend(engine);
      final debrid = _ResolvingDebrid();
      final credentials = _Credentials()
        ..value = 'torbox-secret'
        ..jimaku = 'jimaku-secret';
      final subtitles = _LearningSubtitles();
      const launch = PlaybackLaunch(
        media: Media(
          id: 42,
          title: MediaTitle(userPreferred: 'Learning Show'),
          episodes: 12,
        ),
        episode: 7,
        magnet: '0123456789abcdef0123456789abcdef01234567',
        service: DebridService.torbox,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackBackendProvider.overrideWithValue(backend),
            playbackProbeTransportProvider.overrideWithValue(_ProbeTransport()),
            settingsRepositoryProvider.overrideWithValue(
              _SettingsRepository(
                const Settings(debridService: DebridService.torbox),
              ),
            ),
            credentialStoreProvider.overrideWithValue(credentials),
            debridClientsProvider.overrideWithValue({
              DebridService.torbox: debrid,
            }),
            learningSubtitleRepositoryProvider.overrideWithValue(subtitles),
            languageLearningToolsProvider.overrideWithValue(
              _FakeLearningTools(),
            ),
          ],
          child: MaterialApp(
            theme: buildShiruTheme(),
            home: const PlayerPage(initialLaunch: launch),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      engine.states.add(
        const PlaybackSnapshot(
          generation: 1,
          phase: PlaybackPhase.playing,
          duration: Duration(minutes: 24),
          audioTracks: [
            MediaTrack(id: 'audio-ja', kind: TrackKind.audio, language: 'ja'),
          ],
          subtitleTracks: [
            MediaTrack(
              id: 'sub-en',
              kind: TrackKind.subtitle,
              language: 'en',
              codec: 'ass',
            ),
          ],
          selectedPrimarySubtitle: 'sub-en',
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Subtitles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Learning'));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(subtitles.queries.single.anilistId, 42);
      expect(subtitles.queries.single.episode, 7);
      expect(subtitles.credentials, ['jimaku-secret']);
      expect(engine.calls, contains('subtitle:sub-en:true'));
      expect(engine.calls, contains('add-subtitle'));
      expect(engine.addedSubtitleSource, 'file:///cache/show-07.ass');
      expect(engine.addedSubtitleLanguage, 'ja');
      expect(find.textContaining('cached for this episode'), findsOneWidget);
    },
  );

  testWidgets(
    'a Japanese fetch finishing after Styled is restored stays cached only',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = _FakeEngine();
      final pending = Completer<LearningSubtitleMatch?>();
      final subtitles = _LearningSubtitles(pending: pending);
      final credentials = _Credentials()
        ..value = 'torbox-secret'
        ..jimaku = 'jimaku-secret';
      const launch = PlaybackLaunch(
        media: Media(
          id: 42,
          title: MediaTitle(userPreferred: 'Learning Show'),
          episodes: 12,
        ),
        episode: 7,
        magnet: '0123456789abcdef0123456789abcdef01234567',
        service: DebridService.torbox,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackBackendProvider.overrideWithValue(_FakeBackend(engine)),
            settingsRepositoryProvider.overrideWithValue(
              _SettingsRepository(
                const Settings(debridService: DebridService.torbox),
              ),
            ),
            credentialStoreProvider.overrideWithValue(credentials),
            debridClientsProvider.overrideWithValue({
              DebridService.torbox: _ResolvingDebrid(),
            }),
            learningSubtitleRepositoryProvider.overrideWithValue(subtitles),
          ],
          child: MaterialApp(
            theme: buildShiruTheme(),
            home: const PlayerPage(initialLaunch: launch),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      engine.states.add(
        const PlaybackSnapshot(
          generation: 1,
          phase: PlaybackPhase.playing,
          duration: Duration(minutes: 24),
          audioTracks: [
            MediaTrack(id: 'audio-ja', kind: TrackKind.audio, language: 'ja'),
          ],
          subtitleTracks: [
            MediaTrack(
              id: 'sub-en',
              kind: TrackKind.subtitle,
              language: 'en',
              codec: 'ass',
            ),
          ],
          selectedPrimarySubtitle: 'sub-en',
        ),
      );
      await tester.pump();
      await tester.tap(find.byTooltip('Subtitles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Learning'));
      await tester.pump();
      await tester.tap(find.text('Styled'));
      await tester.pump();

      pending.complete(_LearningSubtitles.match);
      await tester.pumpAndSettle();

      expect(engine.calls, isNot(contains('add-subtitle')));
      expect(engine.calls, contains('render:standard'));
    },
  );

  testWidgets(
    'TorBox launch resolves the requested episode before opening mpv',
    (tester) async {
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

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
      expect(find.byTooltip('Back to episodes'), findsOneWidget);
      expect(find.byTooltip('Previous episode (P)'), findsOneWidget);
      expect(find.byTooltip('Next episode (N)'), findsOneWidget);
      expect(find.textContaining('torbox-secret'), findsNothing);
      expect(find.textContaining('signed-token'), findsNothing);

      await tester.tap(find.byTooltip('Next episode (N)'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(debrid.calls.last, ('torbox-secret', launch.magnet, 8));
      expect(find.text('Episode 8'), findsOneWidget);
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

class _FakeLearningTools implements LanguageLearningTools {
  @override
  LearningDictionaryStatus get dictionaryStatus =>
      const LearningDictionaryStatus(
        phase: LearningDictionaryPhase.ready,
        title: 'JMdict English',
        entryCount: 1,
      );

  @override
  Stream<LearningDictionaryStatus> get dictionaryStatuses =>
      const Stream.empty();

  @override
  Future<List<LearningToken>> tokenizeJapanese(String text) async => const [
    LearningToken(
      surface: '日本語',
      start: 0,
      end: 3,
      baseForm: '日本語',
      reading: 'にほんご',
      romanization: 'nihongo',
      partOfSpeech: 'noun',
      containsKanji: true,
    ),
    LearningToken(surface: 'を', start: 3, end: 4),
    LearningToken(
      surface: '勉強する',
      start: 4,
      end: 8,
      baseForm: '勉強する',
      reading: 'べんきょうする',
      romanization: 'benkyousuru',
      partOfSpeech: 'verb',
      containsKanji: true,
    ),
  ];

  @override
  Future<List<LearningDefinition>> lookup(
    LearningToken token, {
    int limit = 6,
  }) async => const [
    LearningDefinition(
      term: '日本語',
      reading: 'にほんご',
      definitions: ['Japanese language'],
      partsOfSpeech: ['noun'],
    ),
  ];

  @override
  Future<void> installJapaneseEnglishDictionary() async {}

  @override
  Future<void> removeJapaneseEnglishDictionary() async {}

  @override
  Future<void> dispose() async {}
}

class _Credentials implements CredentialStore {
  String? value;
  String? jimaku;

  @override
  Future<String?> read(String key) async =>
      key == debridCredentialKey(DebridService.torbox)
      ? value
      : key == jimakuCredentialKey
      ? jimaku
      : null;

  @override
  Future<void> write(String key, String value) async {
    if (key == jimakuCredentialKey) {
      jimaku = value;
    } else {
      this.value = value;
    }
  }

  @override
  Future<void> delete(String key) async {
    if (key == jimakuCredentialKey) {
      jimaku = null;
    } else {
      value = null;
    }
  }
}

class _LearningSubtitles implements LearningSubtitleRepository {
  _LearningSubtitles({this.pending});

  static const match = LearningSubtitleMatch(
    source: 'file:///cache/show-07.ass',
    title: 'Japanese learning · Jimaku',
    provider: 'Jimaku',
    originalName: 'Show - 07.ass',
  );

  final Completer<LearningSubtitleMatch?>? pending;
  final queries = <LearningSubtitleQuery>[];
  final credentials = <String>[];

  @override
  Future<void> validateCredential(String credential) async {}

  @override
  Future<LearningSubtitleMatch?> findJapanese(
    LearningSubtitleQuery query, {
    required String credential,
  }) async {
    queries.add(query);
    credentials.add(credential);
    return await pending?.future ?? match;
  }
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
