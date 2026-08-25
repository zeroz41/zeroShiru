import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/app/theme/theme.dart';
import 'package:zeroshiru/domain/models/media.dart';
import 'package:zeroshiru/features/home/home_hero.dart';

void main() {
  testWidgets('featured banner exposes working previous and next arrows', (
    tester,
  ) async {
    const media = [
      Media(id: 1, title: MediaTitle(userPreferred: 'First feature')),
      Media(id: 2, title: MediaTitle(userPreferred: 'Second feature')),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildShiruTheme(),
        home: Scaffold(
          body: HomeHero(media: media, onDetails: (_) {}),
        ),
      ),
    );

    expect(find.byTooltip('Previous featured show'), findsOneWidget);
    expect(find.byTooltip('Next featured show'), findsOneWidget);
    expect(find.text('First feature'), findsOneWidget);

    await tester.tap(find.byTooltip('Next featured show'));
    await tester.pumpAndSettle();
    expect(find.text('Second feature'), findsOneWidget);

    await tester.tap(find.byTooltip('Previous featured show'));
    await tester.pumpAndSettle();
    expect(find.text('First feature'), findsOneWidget);
  });
}
