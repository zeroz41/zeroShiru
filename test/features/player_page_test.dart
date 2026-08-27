import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zero/app/theme/theme.dart';
import 'package:zero/application/playback/backend.dart';
import 'package:zero/application/playback/preferences.dart';
import 'package:zero/application/playback/providers.dart';
import 'package:zero/application/playback/request.dart';
import 'package:zero/application/library/providers.dart';
import 'package:zero/application/learning/providers.dart';
import 'package:zero/application/learning/subtitle_providers.dart';
import 'package:zero/application/settings/providers.dart';
import 'package:zero/application/sources/providers.dart';
import 'package:zero/domain/models/availability.dart';
import 'package:zero/domain/models/media.dart';
import 'package:zero/domain/models/settings.dart';
import 'package:zero/domain/models/source_extension.dart';
import 'package:zero/domain/models/torrent.dart';
import 'package:zero/domain/ports/ports.dart';
import 'package:zero/features/player/player_page.dart';
import 'package:zero/domain/ports/http_transport.dart';

class _FakeEngine implements MediaEngine {
  final states = StreamController<PlaybackSnapshot>.broadcast();
  final cues = StreamController<SubtitleCue>.broadcast();
  final secondCues = StreamController<SubtitleCue>.broadcast();
  final metricEvents = StreamController<PlayerMetrics>.broadcast();
  final calls = <String>[];
  final subtitleScales = <double>[];
  PlaybackSnapshot openState = const PlaybackSnapshot(
    generation: 1,
    phase: PlaybackPhase.ready,
    duration: Duration(minutes: 24),
    volume: 0.8,
  );
  String? addedSubtitleSource;
  String? addedSubtitleTitle;
  String? addedSubtitleLanguage;
  PlaybackSnapshot? renderingState;
  PlaybackPreferences? openPreferences;

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
    openPreferences = preferences;
    calls.add('open:${source.name}');
    states.add(openState);
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
  Future<void> setSubtitleRendering(SubtitleRendering mode) async {
    calls.add('render:${mode.name}');
    final next = renderingState;
    if (next != null && next.subtitleRendering == mode) states.add(next);
  }

  @override
  Future<void> setSubtitleDelay(
    Duration delay, {
    bool secondary = false,
  }) async => calls.add('delay:${delay.inMilliseconds}:$secondary');

  @override
  Future<void> setSubtitleScale(double scale) async =>
      subtitleScales.add(scale);

  @override
  Future<String> addSubtitle(
    String source, {
    String? title,
    String? language,
  }) async {
    calls.add('add-subtitle');
    addedSubtitleSource = source;
    addedSubtitleTitle = title;
    addedSubtitleLanguage = language;
    return 'external-ja';
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

Widget _app(
  Widget page,
  _FakeBackend backend, {
  Settings settings = const Settings(),
}) => ProviderScope(
  overrides: [
    playbackBackendProvider.overrideWithValue(backend),
    settingsRepositoryProvider.overrideWithValue(_SettingsRepository(settings)),
    credentialStoreProvider.overrideWithValue(_Credentials()),
    languageLearningToolsProvider.overrideWithValue(_FakeLearningTools()),
  ],
  child: MaterialApp(theme: buildZeroTheme(), home: page),
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

  testWidgets('timeline dragging commits only the final seek position', (
    tester,
  ) async {
    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
    );
    await tester.pump();
    await tester.pump();

    final slider = tester.widget<Slider>(find.byType(Slider).first);
    slider.onChangeStart!(Duration(minutes: 4).inMilliseconds.toDouble());
    slider.onChanged!(Duration(minutes: 6).inMilliseconds.toDouble());
    slider.onChanged!(Duration(minutes: 10).inMilliseconds.toDouble());
    slider.onChangeEnd!(Duration(minutes: 10).inMilliseconds.toDouble());
    await tester.pump();

    expect(engine.calls.where((call) => call.startsWith('seek:')), [
      'seek:600',
    ]);
  });

  testWidgets('subtitle text size updates the active renderer live', (
    tester,
  ) async {
    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
    );
    await tester.pump();
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(PlayerPage)),
    );
    await container
        .read(settingsControllerProvider.notifier)
        .persist((settings) => settings.copyWith(subtitleTextScale: 1.4));
    await tester.pump();
    await tester.pump();

    expect(engine.subtitleScales, isNotEmpty);
    expect(engine.subtitleScales.last, 1.4);
  });

  testWidgets('a new player clears Learning rendering retained by the engine', (
    tester,
  ) async {
    final engine = _FakeEngine()
      ..openState = const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.ready,
        duration: Duration(minutes: 24),
        volume: 0.8,
        subtitleRendering: SubtitleRendering.learning,
      );
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );

    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
    );
    await tester.pump();
    await tester.pump();

    expect(engine.calls, ['open:Episode 03.mkv', 'render:standard', 'play']);
  });

  testWidgets(
    'a new episode restores Learning mode and its language priorities',
    (tester) async {
      final engine = _FakeEngine();
      const source = PlayerFile(
        name: 'Episode 08.mkv',
        url: 'https://cdn.example/video.mkv',
      );

      await tester.pumpWidget(
        _app(
          const PlayerPage(initialSource: source),
          _FakeBackend(engine),
          settings: const Settings(
            audioLanguage: 'eng',
            subtitleLanguage: 'es',
            learningTranslationLanguage: 'de',
            playerSubtitleMode: 'learning',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(engine.openPreferences?.audioLanguage, 'eng');
      expect(engine.openPreferences?.subtitleLanguage, 'jpn');
      expect(engine.openPreferences?.subtitlesEnabled, isTrue);
      expect(engine.calls, contains('render:learning'));
    },
  );

  testWidgets('a new episode restores the remembered subtitle Off mode', (
    tester,
  ) async {
    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 08.mkv',
      url: 'https://cdn.example/video.mkv',
    );

    await tester.pumpWidget(
      _app(
        const PlayerPage(initialSource: source),
        _FakeBackend(engine),
        settings: const Settings(playerSubtitleMode: 'off'),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(engine.openPreferences?.subtitlesEnabled, isFalse);
    expect(engine.calls, contains('render:off'));
  });

  testWidgets('a reopened release restores its primary and secondary timing', (
    tester,
  ) async {
    final engine = _FakeEngine();
    final repository = _SettingsRepository(const Settings());
    await PlaybackTuningStore(repository).write(
      'abcdef0123456789',
      const PlaybackTuning(
        primarySubtitleDelay: Duration(milliseconds: 350),
        secondarySubtitleDelay: Duration(milliseconds: -125),
      ),
    );
    const source = PlayerFile(
      name: 'Episode 08.mkv',
      url: 'https://cdn.example/video.mkv',
      infoHash: 'abcdef0123456789',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackBackendProvider.overrideWithValue(_FakeBackend(engine)),
          settingsRepositoryProvider.overrideWithValue(repository),
          credentialStoreProvider.overrideWithValue(_Credentials()),
          languageLearningToolsProvider.overrideWithValue(_FakeLearningTools()),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const PlayerPage(initialSource: source),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(engine.calls, contains('delay:350:false'));
    expect(engine.calls, contains('delay:-125:true'));
    expect(
      engine.calls.indexOf('delay:350:false'),
      lessThan(engine.calls.indexOf('play')),
    );
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
          theme: buildZeroTheme(),
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
          theme: buildZeroTheme(),
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
    expect(find.text('Subtitles'), findsOneWidget);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Primary track'), findsNothing);

    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    expect(find.text('Primary track'), findsOneWidget);
    expect(find.text('Secondary track'), findsOneWidget);
    await tester.tap(find.text('Secondary track'));
    await tester.pumpAndSettle();
    final japaneseChoice = find.ancestor(
      of: find.textContaining('Japanese'),
      matching: find.byWidgetPredicate(
        (widget) => widget is CheckedPopupMenuItem,
      ),
    );
    await tester.tap(japaneseChoice);
    await tester.pumpAndSettle();
    expect(engine.calls, contains('subtitle:sub-ja:true'));

    await tester.tap(find.text('Learning'));
    await tester.pump();
    expect(engine.calls, contains('render:learning'));
    expect(engine.calls, isNot(contains('audio:audio-ja')));
    expect(engine.calls, contains('subtitle:sub-ja:false'));
    expect(engine.calls, contains('subtitle:sub-en:true'));

    await tester.ensureVisible(find.byTooltip('Later by 0.1 seconds').first);
    await tester.tap(find.byTooltip('Later by 0.1 seconds').first);
    await tester.pump();
    expect(engine.calls, contains('delay:100:false'));

    await tester.ensureVisible(find.text('Styled'));
    await tester.tap(find.text('Styled'));
    await tester.pump();
    expect(engine.calls, contains('subtitle:null:true'));
    expect(engine.calls, contains('subtitle:sub-en:false'));
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();
    expect(
      engine.calls.where((call) => call == 'subtitle:sub-ja:false'),
      hasLength(2),
    );

    await tester.ensureVisible(find.text('Secondary track'));
    await tester.tap(find.text('Secondary track'));
    await tester.pumpAndSettle();
    final offChoice = find.ancestor(
      of: find.text('Off'),
      matching: find.byWidgetPredicate(
        (widget) => widget is CheckedPopupMenuItem,
      ),
    );
    await tester.tap(offChoice);
    await tester.pumpAndSettle();
    expect(engine.calls.last, 'subtitle:null:true');
    expect(
      (await ProviderScope.containerOf(tester.element(find.byType(PlayerPage)))
              .read(settingsControllerProvider.future))
          .learningShowTranslation,
      isFalse,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('learning-layer-translation')),
          )
          .selected,
      isFalse,
    );

    final englishPairings = engine.calls
        .where((call) => call == 'subtitle:sub-en:true')
        .length;
    await tester.ensureVisible(find.text('Styled'));
    await tester.tap(find.text('Styled'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();
    expect(
      engine.calls.where((call) => call == 'subtitle:sub-en:true'),
      hasLength(englishPairings),
    );
    expect(engine.calls.last, 'subtitle:null:true');

    await tester.tapAt(const Offset(10, 400));
    await tester.pumpAndSettle();
    expect(find.text('Subtitles'), findsNothing);
  });

  testWidgets(
    'manual language and subtitle mode choices become next-episode defaults',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final engine = _FakeEngine();
      final repository = _SettingsRepository(
        const Settings(audioLanguage: 'eng'),
      );
      const source = PlayerFile(
        name: 'Episode 03.mkv',
        url: 'https://cdn.example/video.mkv',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackBackendProvider.overrideWithValue(_FakeBackend(engine)),
            settingsRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(_Credentials()),
            languageLearningToolsProvider.overrideWithValue(
              _FakeLearningTools(),
            ),
          ],
          child: MaterialApp(
            theme: buildZeroTheme(),
            home: const PlayerPage(initialSource: source),
          ),
        ),
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
          selectedAudio: 'audio-en',
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Audio track'));
      await tester.pumpAndSettle();
      final japaneseAudio = find.ancestor(
        of: find.text('Japanese'),
        matching: find.byWidgetPredicate(
          (widget) => widget is CheckedPopupMenuItem,
        ),
      );
      await tester.tap(japaneseAudio);
      await tester.pumpAndSettle();
      expect(engine.calls, contains('audio:audio-ja'));
      expect(repository.settings.audioLanguage, 'jpn');

      await tester.tap(find.byTooltip('Subtitles'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Learning'));
      await tester.pumpAndSettle();
      expect(repository.settings.playerSubtitleMode, 'learning');
    },
  );

  testWidgets('Learning recognizes Japanese and translation track titles', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 03.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
    );
    await tester.pump();
    await tester.pump();

    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        duration: Duration(minutes: 24),
        audioTracks: [
          MediaTrack(
            id: 'audio-commentary',
            kind: TrackKind.audio,
            title: 'Japanese Commentary',
            isDefault: true,
          ),
          MediaTrack(
            id: 'audio-main',
            kind: TrackKind.audio,
            title: 'Japanese Original',
          ),
        ],
        subtitleTracks: [
          MediaTrack(
            id: 'sub-ja-signs',
            kind: TrackKind.subtitle,
            title: 'Japanese Signs & Songs',
            isDefault: true,
            codec: 'ass',
          ),
          MediaTrack(
            id: 'sub-ja-full',
            kind: TrackKind.subtitle,
            title: 'Japanese Full Dialogue',
            codec: 'ass',
          ),
          MediaTrack(
            id: 'sub-en-signs',
            kind: TrackKind.subtitle,
            title: 'English Signs & Songs',
            isDefault: true,
            codec: 'ass',
          ),
          MediaTrack(
            id: 'sub-en-full',
            kind: TrackKind.subtitle,
            title: 'English Full Dialogue',
            codec: 'ass',
          ),
        ],
        selectedAudio: 'audio-commentary',
        selectedPrimarySubtitle: 'sub-en-signs',
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Subtitles'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Learning'));
    await tester.pumpAndSettle();

    expect(engine.calls, isNot(contains('audio:audio-main')));
    expect(engine.calls, contains('subtitle:sub-ja-full:false'));
    expect(engine.calls, contains('subtitle:sub-en-full:true'));

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        position: Duration(seconds: 12),
        duration: Duration(minutes: 24),
        subtitleRendering: SubtitleRendering.learning,
        subtitleTracks: [
          MediaTrack(
            id: 'sub-ja-full',
            kind: TrackKind.subtitle,
            title: 'Japanese Full Dialogue',
            codec: 'ass',
          ),
          MediaTrack(
            id: 'sub-en-full',
            kind: TrackKind.subtitle,
            title: 'English Full Dialogue',
            codec: 'ass',
          ),
        ],
        selectedPrimarySubtitle: 'sub-ja-full',
        selectedSecondarySubtitle: 'sub-en-full',
      ),
    );
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja-full',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: '日本語',
      ),
    );
    engine.secondCues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-en-full',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: 'Japanese language',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Japanese language'), findsOneWidget);
  });

  testWidgets('learning mode renders native tokens and local definitions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    final backend = _FakeBackend(engine);
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(
        const PlayerPage(initialSource: source),
        backend,
        settings: const Settings(subtitleTextScale: 1.2),
      ),
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
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('learning-translation')))
          .style
          ?.fontSize,
      closeTo(57.6, 0.01),
    );
    expect(
      tester.widget<Text>(find.text('日本語')).style?.fontSize,
      closeTo(57.6, 0.01),
    );
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsNothing,
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('日本語')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Japanese language'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsOneWidget,
    );
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('learning-definition-panel'))),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsOneWidget,
    );

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsNothing,
    );
    await mouse.removePointer();

    final tokenInteraction = find.byWidgetPredicate(
      (widget) =>
          widget is Focus &&
          widget.focusNode?.debugLabel == 'Learning word 日本語',
    );
    final tokenGesture = find
        .descendant(
          of: tokenInteraction,
          matching: find.byType(GestureDetector),
        )
        .first;
    Focus.of(tester.element(tokenGesture)).requestFocus();
    await tester.pump();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<Focus>(tokenInteraction).focusNode),
    );
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(engine.calls.where((call) => call.startsWith('seek:')), isEmpty);
    final secondTokenInteraction = find.byWidgetPredicate(
      (widget) =>
          widget is Focus &&
          widget.focusNode?.debugLabel == 'Learning word 勉強する',
    );
    expect(
      FocusManager.instance.primaryFocus,
      same(tester.widget<Focus>(secondTokenInteraction).focusNode),
    );
    expect(find.text('勉強する'), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsNothing,
    );

    await tester.tap(find.text('日本語'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Japanese language'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('learning-definition-panel')),
        matching: find.byIcon(Icons.close_rounded),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('learning-definition-panel')),
      findsNothing,
    );
  });

  testWidgets(
    'Learning aligns all translation cues overlapping the Japanese window',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final engine = _FakeEngine();
      const source = PlayerFile(
        name: 'Episode 04.mkv',
        url: 'https://cdn.example/video.mkv',
      );
      await tester.pumpWidget(
        _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
      );
      await tester.pump();
      await tester.pump();

      engine.states.add(
        const PlaybackSnapshot(
          generation: 1,
          phase: PlaybackPhase.playing,
          position: Duration(seconds: 13),
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
      await tester.pump();
      engine.secondCues.add(
        const SubtitleCue(
          generation: 1,
          trackId: 'sub-en',
          start: Duration(seconds: 10),
          end: Duration(milliseconds: 11100),
          plainText: 'First translated line',
        ),
      );
      await tester.pump();
      engine.secondCues.add(
        const SubtitleCue(
          generation: 1,
          trackId: 'sub-en',
          start: Duration(milliseconds: 11200),
          end: Duration(milliseconds: 12400),
          plainText: 'Second translated line',
        ),
      );
      await tester.pump();
      engine.secondCues.add(
        const SubtitleCue(
          generation: 1,
          trackId: 'sub-en',
          start: Duration.zero,
          end: Duration.zero,
          plainText: '',
        ),
      );
      await tester.pump();
      engine.cues.add(
        const SubtitleCue(
          generation: 1,
          trackId: 'sub-ja',
          start: Duration(milliseconds: 10500),
          end: Duration(seconds: 14),
          plainText: '二つの行',
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text('First translated line\nSecond translated line'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Learning does not attach an unrelated old translation cue', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
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
    await tester.pump();
    engine.secondCues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-en',
        start: Duration(seconds: 2),
        end: Duration(seconds: 4),
        plainText: 'Unrelated translation',
      ),
    );
    await tester.pump();
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration(seconds: 10),
        end: Duration(seconds: 14),
        plainText: '日本語を勉強する',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('Unrelated translation'), findsNothing);
    expect(find.byKey(const ValueKey('learning-translation')), findsNothing);
  });

  testWidgets(
    'a normal gap in the Japanese timing does not claim the track is missing',
    (tester) async {
      tester.view.physicalSize = const Size(640, 480);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final engine = _FakeEngine();
      const source = PlayerFile(
        name: 'Episode 04.mkv',
        url: 'https://cdn.example/video.mkv',
      );
      await tester.pumpWidget(
        _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
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

      expect(find.text('Study Japanese'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('learning-text-track-required')),
        findsNothing,
      );
      expect(
        tester
            .widget<Align>(
              find.byKey(const ValueKey('learning-subtitle-overlay')),
            )
            .alignment,
        Alignment.bottomCenter,
      );
    },
  );

  testWidgets('an MPV cue transition is not delayed by a stale position tick', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
    );
    await tester.pump();
    await tester.pump();

    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        // The position stream can still be behind when MPV has already
        // activated the cue on its own clock.
        position: Duration(milliseconds: 9400),
        duration: Duration(minutes: 24),
        subtitleRendering: SubtitleRendering.learning,
        subtitleTracks: [
          MediaTrack(id: 'sub-ja', kind: TrackKind.subtitle, language: 'ja'),
        ],
        selectedPrimarySubtitle: 'sub-ja',
      ),
    );
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration(seconds: 10),
        end: Duration(seconds: 14),
        plainText: '日本語を勉強する',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('日本語'), findsOneWidget);

    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration.zero,
        end: Duration.zero,
        plainText: '',
      ),
    );
    await tester.pump();

    expect(find.text('日本語'), findsNothing);
  });

  testWidgets('an open-ended cue cannot survive a distant forward seek', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
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
        ],
        selectedPrimarySubtitle: 'sub-ja',
      ),
    );
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration(seconds: 10),
        plainText: '日本語を勉強する',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('日本語'), findsOneWidget);

    // MediaKitEngine clears both active cues synchronously before committing
    // a discontinuous seek.
    engine.cues.add(
      const SubtitleCue(
        generation: 1,
        trackId: 'sub-ja',
        start: Duration.zero,
        end: Duration.zero,
        plainText: '',
      ),
    );
    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        position: Duration(minutes: 12),
        duration: Duration(minutes: 24),
        subtitleRendering: SubtitleRendering.learning,
        subtitleTracks: [
          MediaTrack(id: 'sub-ja', kind: TrackKind.subtitle, language: 'ja'),
        ],
        selectedPrimarySubtitle: 'sub-ja',
      ),
    );
    await tester.pump();

    expect(find.text('日本語'), findsNothing);
  });

  testWidgets('learning text can show kana and romaji without kanji', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(
        const PlayerPage(initialSource: source),
        _FakeBackend(engine),
        settings: const Settings(
          learningShowJapanese: false,
          learningShowRomaji: true,
        ),
      ),
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
        ],
        selectedPrimarySubtitle: 'sub-ja',
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
    await tester.pump();
    await tester.pump();

    expect(find.text('日本語'), findsNothing);
    expect(find.text('にほんご'), findsOneWidget);
    expect(find.text('nihongo'), findsOneWidget);
  });

  testWidgets('Learning never substitutes a different translation language', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      _app(const PlayerPage(initialSource: source), _FakeBackend(engine)),
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
          MediaTrack(id: 'sub-pt', kind: TrackKind.subtitle, language: 'pt-BR'),
        ],
        selectedPrimarySubtitle: 'sub-ja',
        selectedSecondarySubtitle: 'sub-pt',
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
        trackId: 'sub-pt',
        start: Duration(seconds: 10),
        end: Duration(seconds: 15),
        plainText: 'Estude japonês',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('日本語'), findsOneWidget);
    expect(find.text('Estude japonês'), findsNothing);
    expect(find.byKey(const ValueKey('learning-translation')), findsNothing);
  });

  testWidgets('player chips toggle Kanji, Kana, Romaji, and Translation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = _FakeEngine();
    final repository = _SettingsRepository(const Settings());
    const source = PlayerFile(
      name: 'Episode 04.mkv',
      url: 'https://cdn.example/video.mkv',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackBackendProvider.overrideWithValue(_FakeBackend(engine)),
          settingsRepositoryProvider.overrideWithValue(repository),
          credentialStoreProvider.overrideWithValue(_Credentials()),
          languageLearningToolsProvider.overrideWithValue(_FakeLearningTools()),
        ],
        child: MaterialApp(
          theme: buildZeroTheme(),
          home: const PlayerPage(initialSource: source),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    engine.states.add(
      const PlaybackSnapshot(
        generation: 1,
        phase: PlaybackPhase.playing,
        duration: Duration(minutes: 24),
        subtitleRendering: SubtitleRendering.learning,
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Subtitles'));
    await tester.pumpAndSettle();
    expect(find.text('Learning layers'), findsOneWidget);
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('learning-layer-kanji')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<FilterChip>(
            find.byKey(const ValueKey('learning-layer-romaji')),
          )
          .selected,
      isFalse,
    );

    await tester.tap(find.byKey(const ValueKey('learning-layer-kanji')));
    await tester.tap(find.byKey(const ValueKey('learning-layer-romaji')));
    await tester.pump();

    expect(repository.settings.learningShowJapanese, isFalse);
    expect(repository.settings.learningShowFurigana, isTrue);
    expect(repository.settings.learningShowRomaji, isTrue);
    expect(repository.settings.learningShowTranslation, isTrue);
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
            theme: buildZeroTheme(),
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
      engine.renderingState = const PlaybackSnapshot(
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
        subtitleRendering: SubtitleRendering.learning,
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
      expect(engine.calls.where((call) => call == 'audio:audio-ja'), isEmpty);
      expect(
        engine.calls.where((call) => call == 'subtitle:sub-en:true'),
        hasLength(2),
      );
      expect(engine.addedSubtitleSource, 'file:///cache/show-07.ass');
      expect(engine.addedSubtitleLanguage, 'ja');
      expect(find.textContaining('cached for this episode'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('advanced-subtitle-settings')),
      );
      await tester.pumpAndSettle();
      final primaryTrack = find.byKey(const ValueKey('primary-subtitle-track'));
      expect(
        find.descendant(of: primaryTrack, matching: find.text('Off')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: primaryTrack,
          matching: find.text('Unavailable track'),
        ),
        findsOneWidget,
      );
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
            theme: buildZeroTheme(),
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
      final sources = _EpisodeSources();
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
        releaseEpisode: 19,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackBackendProvider.overrideWithValue(backend),
            playbackProbeTransportProvider.overrideWithValue(probe),
            settingsRepositoryProvider.overrideWithValue(repository),
            credentialStoreProvider.overrideWithValue(credentials),
            sourceResolverProvider.overrideWithValue(sources),
            debridClientsProvider.overrideWithValue({
              DebridService.torbox: debrid,
            }),
          ],
          child: MaterialApp(
            theme: buildZeroTheme(),
            home: const PlayerPage(initialLaunch: launch),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(debrid.calls, [('torbox-secret', launch.magnet, 19)]);
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
      for (var turn = 0; turn < 10; turn++) {
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 50));

      expect(sources.queries.map((query) => query.episode), [8]);
      expect(debrid.inspections, isNotEmpty);
      expect(debrid.calls.last, (
        'torbox-secret',
        'magnet:?xt=urn:btih:8888888888888888888888888888888888888888',
        20,
      ));
      expect(find.text('Episode 8'), findsOneWidget);
    },
  );

  testWidgets(
    'automatic launch falls through when the first ranked release rejects the episode',
    (tester) async {
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final engine = _FakeEngine();
      final debrid = _FallbackDebrid();
      final credentials = _Credentials()..value = 'torbox-secret';
      const badMagnet =
          'magnet:?xt=urn:btih:1111111111111111111111111111111111111111';
      const goodMagnet =
          'magnet:?xt=urn:btih:2222222222222222222222222222222222222222';
      const launch = PlaybackLaunch(
        media: Media(
          id: 43,
          title: MediaTitle(userPreferred: 'Fallback Show'),
          episodes: 12,
        ),
        episode: 3,
        magnet: badMagnet,
        service: DebridService.torbox,
        alternatives: [PlaybackRelease(magnet: goodMagnet, releaseEpisode: 3)],
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
              DebridService.torbox: debrid,
            }),
          ],
          child: MaterialApp(
            theme: buildZeroTheme(),
            home: const PlayerPage(initialLaunch: launch),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(debrid.magnets, [badMagnet, goodMagnet]);
      expect(engine.calls.take(2), ['open:Show - 03.mkv', 'play']);
      expect(find.text('Episode 3'), findsOneWidget);
      expect(find.textContaining('does not hold'), findsNothing);
    },
  );

  testWidgets(
    'a debrid client cannot leave player resolution pending forever',
    (tester) async {
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final engine = _FakeEngine();
      final credentials = _Credentials()..value = 'torbox-secret';
      const launch = PlaybackLaunch(
        media: Media(
          id: 404,
          title: MediaTitle(userPreferred: 'Deadline Show'),
          episodes: 1,
        ),
        episode: 1,
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
              DebridService.torbox: _PendingDebrid(),
            }),
          ],
          child: MaterialApp(
            theme: buildZeroTheme(),
            home: const PlayerPage(initialLaunch: launch),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Resolving episode 1'), findsOneWidget);

      await tester.pump(const Duration(seconds: 66));
      await tester.pump();

      expect(
        find.textContaining('did not prepare the release'),
        findsOneWidget,
      );
      expect(find.text('Try again'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _SettingsRepository implements SettingsRepository {
  _SettingsRepository(this.settings);

  Settings settings;
  final values = <String, Object?>{};
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
  T read<T>(String key, T fallback) {
    final value = values[key];
    return value is T ? value : fallback;
  }

  @override
  Future<void> write<T>(String key, T value) async {
    values[key] = value;
  }
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
  final inspections = <List<String>>[];

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
  Future<Map<String, DebridAvailabilityDetail>> inspectAvailability(
    String apiKey,
    List<String> hashes,
  ) async {
    inspections.add(hashes);
    return const {};
  }

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

class _FallbackDebrid extends _ResolvingDebrid {
  final magnets = <String>[];

  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) async {
    magnets.add(magnet);
    if (magnet.contains('1111111111')) {
      throw const DebridException(
        DebridErrorKind.rejected,
        'The release does not hold the requested episode.',
      );
    }
    const target = PlayerFile(
      name: 'Show - 03.mkv',
      url: 'https://cdn.example/fallback.mkv',
    );
    return const ResolvedDebrid(
      hash: '2222222222222222222222222222222222222222',
      name: 'Fallback Show',
      files: [target],
      target: target,
    );
  }
}

class _EpisodeSources implements SourceResolver {
  final queries = <TorrentQuery>[];

  static const extension = SourceExtension(
    id: 'episodes',
    name: 'Episode source',
    version: '1',
    origin: 'test',
    supported: true,
    enabled: true,
  );

  @override
  Stream<SourceSearchBatch> search(TorrentQuery query, {bool movie = false}) {
    queries.add(query);
    return Stream.value(
      const SourceSearchBatch(
        source: extension,
        results: [
          TorrentResult(
            title: 'Clean Player Show 20 1080p',
            link:
                'magnet:?xt=urn:btih:8888888888888888888888888888888888888888',
            hash: '8888888888888888888888888888888888888888',
            mappedEpisode: 20,
            seeders: 20,
          ),
        ],
      ),
    );
  }

  @override
  Future<SourceCatalog> catalog() async =>
      const SourceCatalog(extensions: [extension]);

  @override
  Future<SourceCatalog> install(String source) => catalog();

  @override
  Future<SourceCatalog> remove(String source) => catalog();

  @override
  Future<SourceCatalog> setEnabled(String id, bool enabled) => catalog();

  @override
  Future<SourceCatalog> updateSettings(
    String id,
    Map<String, Object?> settings,
  ) => catalog();

  @override
  Future<bool> validate(String id) async => true;
}

class _PendingDebrid extends _ResolvingDebrid {
  @override
  Future<ResolvedDebrid> resolve(
    String apiKey,
    String magnet, {
    int? episode,
  }) => Completer<ResolvedDebrid>().future;
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
