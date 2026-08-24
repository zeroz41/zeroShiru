import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/application/playback/backend.dart';
import 'package:zeroshiru/application/playback/providers.dart';
import 'package:zeroshiru/domain/models/torrent.dart';
import 'package:zeroshiru/domain/ports/media_engine.dart';
import 'package:zeroshiru/features/player/player_page.dart';

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
  Future<void> open(PlayerFile source, {ResumePoint? resume}) async {
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
}
