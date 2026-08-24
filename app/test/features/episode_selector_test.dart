import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/features/library/episode_selector.dart';

void main() {
  testWidgets(
    'episode selector filters, jumps, and reports the exact episode',
    (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildShiruTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: EpisodeSelector(
                episodeCount: 80,
                watchedThrough: 5,
                selectedEpisode: 6,
                onSelected: (episode) => selected = episode,
              ),
            ),
          ),
        ),
      );

      expect(find.text('6 of 80'), findsOneWidget);
      expect(find.byKey(const ValueKey('episode-1')), findsOneWidget);
      expect(find.text('Up next'), findsOneWidget);

      await tester.tap(find.text('Unwatched'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('episode-1')), findsNothing);
      expect(find.byKey(const ValueKey('episode-6')), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('episode-search')),
        '42',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('episode-42')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('episode-42')));
      expect(selected, 42);
    },
  );
}
