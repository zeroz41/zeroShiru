// Pack episode selection, ported from crates/core/src/pick.rs — both test mods:
// the injected-parser cases and the ones driving the real recognizer. Every case
// in the second group is a way playback silently plays the wrong episode when
// the recognizer regresses.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/infrastructure/media/pick.dart';

PackParser okParse(List<ParsedName?> entries) =>
    (_) => entries;

ParsedName numbered(List<double> numbers) =>
    ParsedName(episodeNumbers: numbers);

ParsedName extra(List<double> numbers) =>
    ParsedName(episodeNumbers: numbers, isExtra: true);

List<PackFile> pack(int first, int last) => [
  for (var n = first; n <= last; n++)
    PackFile('/Episode ${n.toString().padLeft(3, '0')}.mkv', 1000),
];

void main() {
  group('with injected parse results', () {
    test('a large pack yields exactly the requested episode', () {
      final files = pack(1, 200);
      final parsed = <ParsedName?>[
        for (var n = 1; n <= 200; n++) numbered([n.toDouble()]),
      ];
      expect(pickEpisodeFile(files, 150.0, okParse(parsed)), 149);
    });

    test('creditless openings never shadow the real episode', () {
      // NCOP1 parses as episode 1 with an anime_type — the real episode 1 must win
      final files = [
        const PackFile('/NCOP1.mkv', 5000),
        const PackFile('/Episode 01.mkv', 1000),
      ];
      final parsed = [
        extra([1.0]),
        numbered([1.0]),
      ];
      expect(pickEpisodeFile(files, 1.0, okParse(parsed)), 1);
    });

    test('a pack of only extras can still serve them by number', () {
      final files = [
        const PackFile('/NCOP1.mkv', 1),
        const PackFile('/NCOP2.mkv', 1),
      ];
      final parsed = [
        extra([1.0]),
        extra([2.0]),
      ];
      expect(pickEpisodeFile(files, 2.0, okParse(parsed)), 1);
    });

    test('a double episode file matches both of its episodes', () {
      final files = [
        const PackFile('/Ep 01-02.mkv', 1),
        const PackFile('/Ep 03.mkv', 1),
      ];
      final parsed = [
        numbered([1.0, 2.0]),
        numbered([3.0]),
      ];
      expect(pickEpisodeFile(files, 2.0, okParse(parsed)), 0);
      expect(pickEpisodeFile(files, 1.0, okParse(parsed)), 0);
    });

    test(
      'an exact single file beats a batch that merely contains the episode',
      () {
        final files = [
          const PackFile('/Batch 01-12.mkv', 1),
          const PackFile('/Ep 05.mkv', 1),
        ];
        final parsed = [
          numbered([1.0, 12.0]),
          numbered([5.0]),
        ];
        expect(pickEpisodeFile(files, 5.0, okParse(parsed)), 1);
      },
    );

    test(
      'the first match in torrent order wins when a pack ships duplicates',
      () {
        final files = [
          const PackFile('/Ep 05 (1080p).mkv', 1),
          const PackFile('/Ep 05 (720p).mkv', 1),
        ];
        final parsed = [
          numbered([5.0]),
          numbered([5.0]),
        ];
        expect(pickEpisodeFile(files, 5.0, okParse(parsed)), 0);
      },
    );

    test('junk beside the videos never comes back as the pick', () {
      final files = [
        const PackFile('/readme.nfo', 900000),
        const PackFile('/subs/ep1.ass', 900000),
        const PackFile('/Episode 01.mkv', 10),
      ];
      // single video: parsing is skipped entirely
      expect(pickEpisodeFile(files, 1.0, okParse([])), 2);
    });

    test('a release with no videos falls back to the first file', () {
      expect(
        pickEpisodeFile([const PackFile('/readme.nfo', 1)], 1.0, okParse([])),
        0,
      );
      expect(pickEpisodeFile(<PackFile>[], 1.0, okParse([])), isNull);
    });

    test(
      'a partial pack provably lacking the episode refuses instead of guessing',
      () {
        final files = pack(459, 516);
        final parsed = <ParsedName?>[
          for (var n = 459; n <= 516; n++) numbered([n.toDouble()]),
        ];
        expect(
          () => pickEpisodeFile(files, 23.0, okParse(parsed)),
          throwsA(
            isA<EpisodeNotInPack>()
                .having((e) => e.first, 'first', 459.0)
                .having((e) => e.last, 'last', 516.0),
          ),
        );
      },
    );

    test('extras do not stretch the span the error reports', () {
      final files = [...pack(459, 516), const PackFile('/NCOP1.mkv', 1)];
      final parsed = <ParsedName?>[
        for (var n = 459; n <= 516; n++) numbered([n.toDouble()]),
        extra([1.0]),
      ];
      expect(
        () => pickEpisodeFile(files, 23.0, okParse(parsed)),
        throwsA(isA<EpisodeNotInPack>().having((e) => e.first, 'first', 459.0)),
        reason: 'an NCOP1 must not make the span start at 1',
      );
    });

    test('an unproven mismatch falls back to the largest real episode, never an extra', () {
      final files = [
        const PackFile('/NCOP1.mkv', 9000),
        const PackFile('/Something 01.mkv', 500),
        const PackFile('/Something else.mkv', 700),
      ];
      // one file unnumbered -> nothing is proven, largest non-extra wins
      final parsed = [
        extra([1.0]),
        numbered([1.0]),
        const ParsedName(),
      ];
      expect(pickEpisodeFile(files, 5.0, okParse(parsed)), 2);
    });

    test('a parser that throws still yields a playable fallback', () {
      final files = [const PackFile('/a.mkv', 1), const PackFile('/b.mkv', 2)];
      List<ParsedName?> broken(List<String> names) =>
          throw StateError('parser broke');
      expect(pickEpisodeFile(files, 1.0, broken), 1);
    });

    test('the largest file fallback keeps torrent order on ties', () {
      final files = [
        const PackFile('/a.mkv', 5),
        const PackFile('/b.mkv', 5),
        const PackFile('/c.mkv', 5),
      ];
      final parsed = [
        const ParsedName(),
        const ParsedName(),
        const ParsedName(),
      ];
      expect(pickEpisodeFile(files, 1.0, okParse(parsed)), 0);
    });

    test('episode 12 does not match a 12.5 special, and 12.5 can still be asked for', () {
      final files = [
        const PackFile('/Ep 12.5.mkv', 1),
        const PackFile('/Ep 12.mkv', 1),
      ];
      final parsed = [
        numbered([12.5]),
        numbered([12.0]),
      ];
      expect(pickEpisodeFile(files, 12.0, okParse(parsed)), 1);
      expect(pickEpisodeFile(files, 12.5, okParse(parsed)), 0);
    });

    test('a small release the picker cannot match is handed to the player instead of refused', () {
      // split cour numbered 13-24 asked for episode 1: provably absent by
      // release numbering, but the player's season offsets may still find it
      final files = pack(13, 24);
      final parsed = <ParsedName?>[
        for (var n = 13; n <= 24; n++) numbered([n.toDouble()]),
      ];
      expect(pickPackFile(files, 1.0, okParse(parsed), 1 << 62), isNull);
      // too big to hand over whole: still refused rather than windowed blindly
      expect(
        () => pickPackFile(files, 1.0, okParse(parsed), 5),
        throwsA(isA<EpisodeNotInPack>()),
      );
    });
  });

  // The picker driven by the real recognizer rather than injected parse results.
  // These mirror the Rust real_names mod (and test/unit/debrid/pick.test.js
  // before it, which drove the same cases through the JS anitomy build).
  group('with real names', () {
    String? pick(List<PackFile> files, double episode) {
      final index = pickEpisodeFile(files, episode, parseNames);
      return index == null ? null : files[index].path;
    }

    test('a large pack yields exactly the requested episode', () {
      final files = [
        for (var n = 1; n <= 150; n++)
          PackFile(
            '/Pack/[Group] Show - ${n.toString().padLeft(3, '0')} [1080p].mkv',
            1000,
          ),
      ];
      expect(pick(files, 1.0), '/Pack/[Group] Show - 001 [1080p].mkv');
      expect(pick(files, 100.0), '/Pack/[Group] Show - 100 [1080p].mkv');
      expect(pick(files, 150.0), '/Pack/[Group] Show - 150 [1080p].mkv');
    });

    test('padding never matters', () {
      for (final name in [
        '/Show - 05.mkv',
        '/Show - 005.mkv',
        '/Show S01E05.mkv',
        '/Show.S01.E05.1080p.mkv',
      ]) {
        final files = [
          const PackFile('/Show - 04.mkv', 1000),
          PackFile(name, 1000),
          const PackFile('/Show - 06.mkv', 1000),
        ];
        expect(pick(files, 5.0), name, reason: name);
      }
    });

    test('a half episode is not the episode before it', () {
      final files = [
        const PackFile('/Show - 12.mkv', 1),
        const PackFile('/Show - 12.5.mkv', 1),
        const PackFile('/Show - 13.mkv', 1),
      ];
      expect(pick(files, 12.0), '/Show - 12.mkv');
      expect(pick(files, 12.5), '/Show - 12.5.mkv');
    });

    test('a v2 release still matches its episode number', () {
      final files = [
        const PackFile('/Show - 04.mkv', 1),
        const PackFile('/Show - 05v2.mkv', 1),
        const PackFile('/Show - 06.mkv', 1),
      ];
      expect(pick(files, 5.0), '/Show - 05v2.mkv');
    });

    test('creditless openings never shadow the real episode', () {
      final files = [
        const PackFile('/Extras/[Group] Show - NCOP1.mkv', 300),
        const PackFile('/Extras/[Group] Show - NCED1.mkv', 300),
        const PackFile('/[Group] Show - 01.mkv', 900),
        const PackFile('/[Group] Show - 02.mkv', 900),
      ];
      expect(pick(files, 1.0), '/[Group] Show - 01.mkv');
      expect(pick(files, 2.0), '/[Group] Show - 02.mkv');
    });

    test('specials and OVAs do not shadow same-numbered episodes', () {
      final files = [
        const PackFile('/Specials/[Group] Show - SP01.mkv', 1),
        const PackFile('/Specials/[Group] Show - OVA 02.mkv', 1),
        const PackFile('/[Group] Show - 01.mkv', 1),
        const PackFile('/[Group] Show - 02.mkv', 1),
      ];
      expect(pick(files, 1.0), '/[Group] Show - 01.mkv');
      expect(pick(files, 2.0), '/[Group] Show - 02.mkv');
    });

    test('a pack of only extras can still serve them by number', () {
      final files = [
        const PackFile('/[Group] Show - NCOP1.mkv', 1),
        const PackFile('/[Group] Show - NCOP2.mkv', 1),
      ];
      expect(pick(files, 2.0), '/[Group] Show - NCOP2.mkv');
    });

    test('a batch file covers the episodes it spans', () {
      final files = [
        const PackFile('/[Group] Show - 01-12 [Batch].mkv', 5000),
        const PackFile('/[Group] Show - 13.mkv', 900),
      ];
      expect(pick(files, 5.0), '/[Group] Show - 01-12 [Batch].mkv');
      expect(pick(files, 13.0), '/[Group] Show - 13.mkv');
      // and a dedicated file beats the batch around it
      final withSingle = [
        const PackFile('/[Group] Show - 01-12 [Batch].mkv', 5000),
        const PackFile('/[Group] Show - 05.mkv', 900),
      ];
      expect(pick(withSingle, 5.0), '/[Group] Show - 05.mkv');
    });

    test(
      'the first match in torrent order wins when a pack ships duplicates',
      () {
        final files = [
          const PackFile('/1080p/Show - 05.mkv', 2000),
          const PackFile('/720p/Show - 05.mkv', 900),
        ];
        expect(pick(files, 5.0), '/1080p/Show - 05.mkv');
      },
    );

    test('subtitles and junk beside the videos are never the pick', () {
      final files = [
        const PackFile('/Show - 05.ass', 30),
        const PackFile('/readme.txt', 999999),
        const PackFile('/Show - 05.mkv', 900),
      ];
      expect(pick(files, 5.0), '/Show - 05.mkv');
    });

    // the reported bug: a 459-516 One Piece pack asked for episode 23 played
    // episode 475 — the largest file — because "no match" fell back to "largest
    // video". This is the real file list of that release, scraped from the tracker.
    test('a partial pack asked for an episode it lacks refuses instead of guessing', () {
      final fixture = File('../fixtures/fr-one-piece-459-516.json')
          .readAsStringSync();
      final entries = jsonDecode(fixture) as List<dynamic>;
      final files = [
        for (final entry in entries.cast<Map<String, dynamic>>())
          PackFile(entry['path'] as String, entry['size'] as int),
      ];

      late final EpisodeNotInPack error;
      try {
        pickEpisodeFile(files, 23.0, parseNames);
        fail('a 459-516 pack must refuse episode 23');
      } on EpisodeNotInPack catch (caught) {
        error = caught;
      }
      expect(
        error.first,
        459.0,
        reason: 'the message must say what the release really holds',
      );
      expect(error.last, 516.0);
      expect(error.toString(), contains('459-516'));
      expect(error.toString(), contains('episode 23'));

      // and the same pack still serves what it does hold
      expect(pick(files, 475.0), '/One Piece - 475 v2 [F-R][b1929031].mkv');
      expect(pick(files, 459.0), '/One Piece - 459 v2 [F-R][9d4e6bc5].mkv');
      expect(pick(files, 516.0), '/One Piece - 516 v2 [F-R][54ce21cf].mkv');
    });

    test(
      'extras in a partial pack do not stretch the span the error reports',
      () {
        final files = [
          const PackFile('/Extras/Show - NCOP1.mkv', 5000),
          const PackFile('/Show - 40.mkv', 900),
          const PackFile('/Show - 41.mkv', 950),
        ];
        expect(
          () => pickEpisodeFile(files, 3.0, parseNames),
          throwsA(
            isA<EpisodeNotInPack>()
                .having((e) => e.first, 'first', 40.0)
                .having((e) => e.last, 'last', 41.0),
          ),
          reason: 'the NCOP parsing as episode 1 must not make the pack claim to start at 1',
        );
      },
    );

    test('an unproven mismatch falls back to the largest real episode, never an extra', () {
      final files = [
        const PackFile('/Extras/Show - NCOP1.mkv', 5000),
        const PackFile('/Show - 01.mkv', 900),
        const PackFile('/Show - 02.mkv', 950),
        const PackFile('/Show - Unnumbered Special.mkv', 800),
      ];
      expect(pick(files, 40.0), '/Show - 02.mkv');
    });

    test('a small release the picker cannot match is handed to the player', () {
      final files = [
        for (var n = 13; n <= 24; n++) PackFile('/[Group] Show - $n.mkv', 1000),
      ];
      expect(
        pickPack(files, 1.0, 12),
        isNull,
        reason: 'no pick means the player decides',
      );
      expect(
        () => pickEpisodeFile(files, 1.0, parseNames),
        throwsA(isA<EpisodeNotInPack>()),
        reason: 'the strict picker still says what it knows',
      );
    });

    test('a release too big to hand over whole is still refused', () {
      final files = [
        for (var n = 459; n <= 516; n++) PackFile('/One Piece - $n.mkv', 1000),
      ];
      expect(
        () => pickPack(files, 23.0, 12),
        throwsA(isA<EpisodeNotInPack>()),
        reason: 'windowing this would play an arbitrary episode',
      );
      expect(pickPack(files, 475.0, 12), 16);
    });
  });
}
