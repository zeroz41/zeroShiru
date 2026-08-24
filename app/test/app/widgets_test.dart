import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/app/theme/tokens.dart';
import 'package:zeroshiru/app/widgets/accent_pill.dart';
import 'package:zeroshiru/app/widgets/ambient_background.dart';
import 'package:zeroshiru/app/widgets/empty_state.dart';
import 'package:zeroshiru/app/widgets/poster_card.dart';
import 'package:zeroshiru/app/widgets/skeleton.dart';
import 'package:zeroshiru/app/widgets/titled_rail.dart';

Widget _app(Widget child) {
  return MaterialApp(
    theme: buildShiruTheme(),
    home: Scaffold(body: child),
  );
}

void main() {
  testWidgets('PosterCard builds and shows its title', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _app(
        Center(
          child: PosterCard(
            title: 'Sousou no Frieren',
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    expect(find.text('Sousou no Frieren'), findsOneWidget);
    await tester.tap(find.byType(PosterCard));
    await tester.pump(ShiruTokens.motion);
    expect(tapped, isTrue);
  });

  testWidgets('PosterCard shows the AIRING badge when airing',
      (tester) async {
    await tester.pumpWidget(
      _app(
        const Center(
          child: PosterCard(title: 'Ongoing Show', airing: true),
        ),
      ),
    );
    expect(find.text('AIRING'), findsOneWidget);
    // The airing ring animates forever; settle a bounded amount.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('TitledRail renders its header and children', (tester) async {
    await tester.pumpWidget(
      _app(
        TitledRail(
          title: 'Trending Now',
          children: [
            for (var i = 0; i < 5; i++)
              SizedBox(
                key: ValueKey('cell-$i'),
                width: 146,
                height: 180,
              ),
          ],
        ),
      ),
    );
    expect(find.text('Trending Now'), findsOneWidget);
    expect(find.byKey(const ValueKey('cell-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('cell-4')), findsOneWidget);
  });

  testWidgets('AccentPill renders both variants and taps', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            AccentPill(
              label: 'Watch Now',
              icon: Icons.play_arrow_rounded,
              onTap: () => taps++,
            ),
            const AccentPill(
              label: 'View Details',
              variant: AccentPillVariant.alt,
            ),
          ],
        ),
      ),
    );
    expect(find.text('Watch Now'), findsOneWidget);
    expect(find.text('View Details'), findsOneWidget);
    await tester.tap(find.text('Watch Now'));
    await tester.pump(ShiruTokens.motion);
    expect(taps, 1);
  });

  testWidgets('EmptyState shows glyph and message', (tester) async {
    await tester.pumpWidget(
      _app(const EmptyState(message: 'Nothing here yet')),
    );
    expect(find.text('Nothing here yet'), findsOneWidget);
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, ShiruTokens.emptyGlyphSize);
    expect(icon.color, ShiruTokens.emptyGlyphColor);
  });

  testWidgets('Skeleton shimmers without settling', (tester) async {
    await tester.pumpWidget(
      _app(const Skeleton(width: 100, height: 40)),
    );
    expect(find.byType(Skeleton), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('AmbientBackground paints statically around its child',
      (tester) async {
    await tester.pumpWidget(
      _app(const AmbientBackground(child: Text('page'))),
    );
    expect(find.text('page'), findsOneWidget);
    // Static: nothing scheduled, nothing animating.
    expect(tester.hasRunningAnimations, isFalse);
  });
}
