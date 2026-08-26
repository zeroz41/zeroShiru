// The 14 recognizer vectors from crates/media/src/filename.rs, ported verbatim.
// Every one of these is a way a number that is not an episode gets played as one.
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/infrastructure/media/filename.dart';

List<double> episodes(String name) => parseFilename(name).episodeNumbers;

void main() {
  test('reads the fansub form whatever the padding', () {
    for (final name in ['Show - 5.mkv', 'Show - 05.mkv', 'Show - 005.mkv']) {
      expect(episodes(name), [5.0], reason: name);
    }
  });

  test('a frame size is not a season and an episode', () {
    // `1920x1080` used to read as season 1920 episode 1080, so every file in a
    // pack claimed the same episode, the wanted one was in none of them, and
    // the whole release was refused as not holding it
    for (final name in [
      'Show.-.05.1920x1080.x264.FLAC.mkv',
      '[Group] Show 05 1280x720 AAC.mkv',
      'Show - 05 [848x480].mkv',
    ]) {
      expect(episodes(name), [5.0], reason: name);
    }
    // and the form it was written for still reads
    expect(episodes('Show 1x05.mkv'), [5.0]);
    expect(episodes('Show 12x05.mkv'), [5.0]);
  });

  test('reads season and episode forms', () {
    expect(episodes('Show S01E05.mkv'), [5.0]);
    expect(episodes('Show.S01.E05.1080p.mkv'), [5.0]);
    expect(episodes('Show 1x05.mkv'), [5.0]);
    expect(episodes('Show EP05.mkv'), [5.0]);
    expect(episodes('Show Episode 5.mkv'), [5.0]);
  });

  test('reads ranges as both ends', () {
    expect(episodes('[Group] Show - 01-02.mkv'), [1.0, 2.0]);
    expect(episodes('[Group] Show - 01-12 [Batch].mkv'), [1.0, 12.0]);
    expect(episodes('Show S01E01-E12.mkv'), [1.0, 12.0]);
  });

  test('keeps plus-separated fix episodes discrete', () {
    final parsed = parseFilename('[F-R] One Piece 0487+0490 v3');
    expect(parsed.episodeNumbers, [487.0, 490.0]);
    expect(parsed.coversEpisode(487), isTrue);
    expect(parsed.coversEpisode(488), isFalse);
    expect(parsed.coversEpisode(489), isFalse);
    expect(parsed.coversEpisode(490), isTrue);
  });

  test('keeps decimal episodes whole', () {
    expect(episodes('Show - 12.5.mkv'), [12.5]);
    expect(episodes('Show - 12.mkv'), [12.0]);
  });

  test('a version suffix never hides the episode', () {
    expect(episodes('Show - 05v2.mkv'), [5.0]);
    expect(parseFilename('Show - 05v2.mkv').version, 2);
    expect(episodes('One Piece - 475 v2 [F-R][b1929031].mkv'), [475.0]);
  });

  test('quality tags and CRCs are never episodes', () {
    expect(episodes('[Group] Show - 001 [1080p][b1929031].mkv'), [1.0]);
    expect(episodes('[Group] Show - 05 [1080p][10bit][AAC 5.1].mkv'), [5.0]);
    expect(episodes('[Group] Show [1080p][b1929031].mkv'), isEmpty);
  });

  test('a year alone is not an episode', () {
    expect(episodes('Show (2020).mkv'), isEmpty);
    expect(episodes('Show 2020.mkv'), isEmpty);
    // but a release that numbers past 1900 still reads, because the form says so
    expect(episodes('One Piece - 1015.mkv'), [1015.0]);
  });

  test('extras are named as such and keep their numbers', () {
    final ncop = parseFilename('[Group] Show - NCOP1.mkv');
    expect(ncop.kind, ReleaseKind.creditless);
    expect(ncop.episodeNumbers, [1.0]);
    expect(ncop.isExtra, isTrue);

    final sp = parseFilename('Specials/[Group] Show - SP01.mkv');
    expect(sp.kind, ReleaseKind.special);
    expect(sp.episodeNumbers, [1.0]);

    final ova = parseFilename('Specials/[Group] Show - OVA 02.mkv');
    expect(ova.kind, ReleaseKind.ova);
    expect(ova.episodeNumbers, [2.0]);
  });

  test('an unnumbered special reads as an extra with no number', () {
    final parsed = parseFilename('Show - Unnumbered Special.mkv');
    expect(parsed.kind, ReleaseKind.special);
    expect(
      parsed.episodeNumbers,
      isEmpty,
      reason: 'guessing a number here plays the wrong file',
    );
  });

  test('only the last path segment is read', () {
    expect(episodes('Season 1/[Group] Show S01E02.mkv'), [2.0]);
    expect(episodes('1080p/Show - 05.mkv'), [5.0]);
  });

  test('a name with nothing to say says nothing', () {
    expect(episodes('Movie.mkv'), isEmpty);
    expect(episodes('readme.txt'), isEmpty);
    expect(episodes(''), isEmpty);
  });

  test('a bracketed number is read only when nothing else answers', () {
    expect(episodes('[Group] Show [05].mkv'), [5.0]);
    // the free-text number wins over the bracketed one
    expect(episodes('[Group] Show - 07 [05].mkv'), [7.0]);
  });

  test('hyphenated titles do not become ranges', () {
    expect(episodes('Re-Zero - 05.mkv'), [5.0]);
    expect(episodes('Show - 12-05.mkv'), [
      12.0,
    ], reason: 'a descending pair is not a range');
  });
}
