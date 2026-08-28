import 'package:flutter_test/flutter_test.dart';
import 'package:zero/application/playback/subtitle_alignment.dart';

Duration _s(double seconds) =>
    Duration(milliseconds: (seconds * 1000).round());

void main() {
  test('a constant lag is measured and negated', () {
    final primary = [for (var i = 0; i < 8; i++) _s(10.0 * i)];
    final secondary = [for (var i = 0; i < 8; i++) _s(10.0 * i + 0.5)];

    expect(
      suggestedSecondaryDelayAdjustment(
        primaryStarts: primary,
        secondaryStarts: secondary,
      ),
      const Duration(milliseconds: -500),
    );
  });

  test('a track running early is shifted later', () {
    final primary = [for (var i = 0; i < 8; i++) _s(10.0 * i)];
    final secondary = [for (var i = 0; i < 8; i++) _s(10.0 * i - 1.2)];

    expect(
      suggestedSecondaryDelayAdjustment(
        primaryStarts: primary,
        secondaryStarts: secondary,
      ),
      const Duration(milliseconds: 1200),
    );
  });

  test('outliers and unpaired lines do not move the median', () {
    final primary = [for (var i = 0; i < 9; i++) _s(10.0 * i)];
    final secondary = [
      for (var i = 0; i < 9; i++) _s(10.0 * i + 0.4),
      // A sign line with no Japanese partner, far from everything.
      _s(300),
    ];

    expect(
      suggestedSecondaryDelayAdjustment(
        primaryStarts: primary,
        secondaryStarts: secondary,
      ),
      const Duration(milliseconds: -400),
    );
  });

  test('near-agreement returns zero instead of churning the tuning', () {
    final primary = [for (var i = 0; i < 8; i++) _s(10.0 * i)];
    final secondary = [for (var i = 0; i < 8; i++) _s(10.0 * i + 0.05)];

    expect(
      suggestedSecondaryDelayAdjustment(
        primaryStarts: primary,
        secondaryStarts: secondary,
      ),
      Duration.zero,
    );
  });

  test('too few observations refuse to guess', () {
    expect(
      suggestedSecondaryDelayAdjustment(
        primaryStarts: [_s(0), _s(10)],
        secondaryStarts: [_s(0.5), _s(10.5)],
      ),
      isNull,
    );
  });

  test('tracks with nothing in common refuse to guess', () {
    final primary = [for (var i = 0; i < 8; i++) _s(10.0 * i)];
    final secondary = [for (var i = 0; i < 8; i++) _s(10.0 * i + 500)];

    expect(
      suggestedSecondaryDelayAdjustment(
        primaryStarts: primary,
        secondaryStarts: secondary,
      ),
      isNull,
    );
  });
}
