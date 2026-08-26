import 'package:flutter_test/flutter_test.dart';
import 'package:zero/infrastructure/debrid/window.dart';

List<String> pack(int length) => [
  for (var index = 1; index <= length; index++)
    '/Episode ${index.toString().padLeft(3, '0')}.mkv',
];

int? position(List<String> files, int episode) {
  final path = '/Episode ${episode.toString().padLeft(3, '0')}.mkv';
  final at = files.indexOf(path);
  return at < 0 ? null : at;
}

void main() {
  test('a pack within the cap is passed through untouched', () {
    final files = pack(60);
    final windowed = windowFiles(files, position(files, 30), 60);
    expect(windowed.length, files.length);
    expect(identical(windowed, files), isTrue);
  });

  test('the requested episode always survives the cap', () {
    final files = pack(200);
    for (final wanted in [1, 2, 30, 100, 170, 199, 200]) {
      final windowed = windowFiles(files, position(files, wanted), 60);
      expect(windowed.length, 60, reason: 'episode $wanted: the cap holds');
      final path = '/Episode ${wanted.toString().padLeft(3, '0')}.mkv';
      expect(
        windowed,
        contains(path),
        reason: 'episode $wanted must survive its own window',
      );
    }
  });

  test('the window centers on the episode', () {
    final files = pack(200);
    final windowed = windowFiles(files, position(files, 100), 60);
    expect(windowed, contains('/Episode 099.mkv'), reason: 'previous episode');
    expect(windowed, contains('/Episode 101.mkv'), reason: 'next episode');
    final index = windowed.indexOf('/Episode 100.mkv');
    expect(
      index,
      inInclusiveRange(25, 35),
      reason: 'episode should sit near the middle, sat at $index',
    );
  });

  test('a window near the start clamps without shrinking', () {
    final files = pack(200);
    final windowed = windowFiles(files, position(files, 3), 60);
    expect(windowed[0], files[0], reason: 'clamped to the start');
    expect(windowed.length, 60, reason: 'and still full size');
  });

  test('a window near the end clamps without running past the pack', () {
    final files = pack(200);
    final windowed = windowFiles(files, position(files, 198), 60);
    expect(windowed[59], files[199], reason: 'clamped to the end');
    expect(windowed.length, 60);
  });

  test('torrent order is preserved', () {
    final files = pack(200);
    final windowed = windowFiles(files, position(files, 100), 60);
    final sorted = List.of(windowed)..sort();
    expect(windowed, sorted, reason: 'files must stay in torrent order');
  });

  test('no target takes the head of the list rather than guessing', () {
    final files = pack(200);
    expect(windowFiles(files, null, 60), files.sublist(0, 60));
  });

  test('a target missing from the list degrades to the head, never empty', () {
    final files = pack(200);
    expect(windowFiles(files, 1 << 60, 60), files.sublist(0, 60));
  });
}
