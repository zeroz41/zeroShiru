import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/application/playback/coverage.dart';
import 'package:zeroshiru/infrastructure/media/filename.dart';

void main() {
  test(
    'a numbered partial batch must actually cover the requested episode',
    () {
      final parsed = parseFilename('[Group] Show - 459-516 [Batch]');

      expect(
        releaseHoldsEpisode(parsed, episode: 23, episodeCount: 1100),
        isFalse,
      );
      expect(releaseHoldsEpisode(parsed, episode: 475), isTrue);
    },
  );

  test(
    'mapped absolute numbering is accepted and handed to file selection',
    () {
      final parsed = parseFilename('[Group] Show - 13-24 [Batch]');

      expect(
        releaseHoldsEpisode(parsed, episode: 1, absoluteEpisode: 13),
        isTrue,
      );
      expect(releaseEpisodeFor(parsed, episode: 1, absoluteEpisode: 13), 13);
    },
  );

  test('plus-separated fix episodes remain discrete rather than a range', () {
    final parsed = parseFilename('[F-R] One Piece 0487+0490 v3');

    expect(releaseHoldsEpisode(parsed, episode: 487), isTrue);
    expect(releaseHoldsEpisode(parsed, episode: 488), isFalse);
    expect(releaseHoldsEpisode(parsed, episode: 489), isFalse);
    expect(releaseHoldsEpisode(parsed, episode: 490), isTrue);
  });

  test('an unnumbered pack remains eligible for member-file inspection', () {
    expect(
      releaseHoldsEpisode(
        parseFilename('[Group] Complete Series [1080p]'),
        episode: 7,
      ),
      isTrue,
    );
  });
}
