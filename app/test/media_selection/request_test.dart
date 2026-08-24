// Which file plays when the user named an episode, ported from
// frontend/test/unit/playback/request.test.js. The player re-derives the episode
// from the resolved file list using watch status, which is right when playback
// chooses for itself and wrong when the user pointed at an episode. On debrid it
// was wrong by a fixed amount, because the resolved list is a window centred on
// the wanted episode: with a 12 file window the lowest episode present is the
// wanted one minus six, so picking episode 10 played 4 and picking 24 played 18.
// These pin the request that now outranks that guess.
import 'package:flutter_test/flutter_test.dart';
import 'package:zeroshiru/application/playback/request.dart';

const media = 21; // One Piece, as it happens

/// A resolved video file, shaped like the ones handleFiles works on.
ResolvedFile file(Object episode, {int? mediaId = media, String? name}) =>
    ResolvedFile(
      name: name ?? 'Show - $episode.mkv',
      media: ResolvedFileMedia(
        mediaId: mediaId,
        episode: episode,
        parsedEpisode: '$episode',
      ),
    );

/// The window a debrid resolve hands the player: maxFiles centred on the episode
/// asked for. The real windowing lives in the debrid layer; this reproduces its
/// shape so the matcher can be tested against it.
List<ResolvedFile> debridWindow(
  int episode, {
  int first = 1,
  int last = 100,
  int maxFiles = 12,
}) {
  final pack = [for (var n = first; n <= last; n++) file(n)];
  if (pack.length <= maxFiles) return pack;
  final index = pack.indexWhere(
    (candidate) => candidate.media?.episode == episode,
  );
  final start = index < 0
      ? 0
      : (index - (maxFiles >> 1)).clamp(0, pack.length - maxFiles);
  return pack.sublist(start, start + maxFiles);
}

void main() {
  test('the episode the user asked for is what plays, not the lowest in the window', () {
    // the exact report: episode 10 played episode 4, episode 24 played 18
    for (final episode in [10, 24]) {
      final files = debridWindow(episode);
      expect(
        files.first.media?.episode,
        isNot(episode),
        reason: 'sanity: the window really does start below the request',
      );
      final played = matchRequestedFile(
        files,
        PlayRequest(episode: episode, mediaId: media),
      );
      expect(
        played?.media?.episode,
        episode,
        reason:
            'asked for $episode, ${files.first.media?.episode} is what used to play',
      );
    }
  });

  test(
    'every episode of a window is reachable, wherever the window had to clamp',
    () {
      for (final episode in [1, 2, 6, 7, 50, 99, 100]) {
        final files = debridWindow(episode);
        expect(
          matchRequestedFile(
            files,
            PlayRequest(episode: episode, mediaId: media),
          )?.media?.episode,
          episode,
          reason: 'episode $episode',
        );
      }
    },
  );

  test('a full torrent pack plays the episode asked for rather than the first one', () {
    // the same guess bites the torrent lane, it is just less visible there: the
    // whole pack is handed over, so the lowest episode present is episode 1
    final files = [for (var n = 1; n <= 100; n++) file(n)];
    expect(
      matchRequestedFile(
        files,
        const PlayRequest(episode: 73, mediaId: media),
      )?.media?.episode,
      73,
    );
  });

  test('no request means playback still chooses for itself', () {
    final files = [file(4), file(5)];
    expect(
      matchRequestedFile(files, null),
      isNull,
      reason: 'the watch-status heuristics must stay in charge',
    );
  });

  test('an episode the release does not hold falls back rather than playing something else', () {
    final files = [file(4), file(5), file(6)];
    expect(
      matchRequestedFile(files, const PlayRequest(episode: 23, mediaId: media)),
      isNull,
      reason: 'no match must not become "play file zero"',
    );
  });

  test("another show's episode in a mixed batch is never what plays", () {
    final files = [
      file(10, mediaId: 999, name: 'Other Show - 10.mkv'),
      file(10),
    ];
    final played = matchRequestedFile(
      files,
      const PlayRequest(episode: 10, mediaId: media),
    );
    expect(
      played?.media?.mediaId,
      media,
      reason: 'the requested media decides between same-numbered episodes',
    );
  });

  test('a file whose media never resolved is still eligible for the release being played', () {
    const unresolved = ResolvedFile(
      name: 'Show - 10.mkv',
      media: ResolvedFileMedia(episode: 10, parsedEpisode: '10'),
    );
    expect(
      matchRequestedFile([
        file(9),
        unresolved,
      ], const PlayRequest(episode: 10, mediaId: media)),
      same(unresolved),
      reason: 'it belongs to the release the user just asked to play',
    );
  });

  test('episode numbers match whether they arrive as numbers or strings', () {
    final files = [file('09'), file('10'), file('11')];
    expect(
      matchRequestedFile(
        files,
        const PlayRequest(episode: 10, mediaId: media),
      )?.media?.episode,
      '10',
    );
    expect(
      matchRequestedFile(
        files,
        const PlayRequest(episode: '10', mediaId: media),
      )?.media?.episode,
      '10',
    );
  });

  test('the parsed episode number is used when the resolver left no episode of its own', () {
    const parsedOnly = ResolvedFile(
      name: 'Show - 10.mkv',
      media: ResolvedFileMedia(mediaId: media, parsedEpisode: '10'),
    );
    expect(
      matchRequestedFile([
        file(9),
        parsedOnly,
      ], const PlayRequest(episode: 10, mediaId: media)),
      same(parsedOnly),
    );
  });

  test(
    'a file holding several episodes serves any episode inside its range',
    () {
      const batched = ResolvedFile(
        name: 'Show - 09-12.mkv',
        media: ResolvedFileMedia(
          mediaId: media,
          episodeRange: EpisodeRange(9, 12),
        ),
      );
      final files = [file(1), batched];
      expect(
        matchRequestedFile(
          files,
          const PlayRequest(episode: 11, mediaId: media),
        ),
        same(batched),
      );
      expect(
        matchRequestedFile(
          files,
          const PlayRequest(episode: 13, mediaId: media),
        ),
        isNull,
        reason: 'and nothing outside it',
      );
    },
  );

  test('an exact episode beats a range that merely contains it', () {
    const batched = ResolvedFile(
      name: 'Show - 09-12.mkv',
      media: ResolvedFileMedia(
        mediaId: media,
        episodeRange: EpisodeRange(9, 12),
      ),
    );
    final exact = file(11);
    expect(
      matchRequestedFile([
        batched,
        exact,
      ], const PlayRequest(episode: 11, mediaId: media)),
      same(exact),
    );
  });

  test('an empty or malformed file list is handled without throwing', () {
    for (final files in <List<ResolvedFile>?>[
      [],
      null,
      [const ResolvedFile()],
      [const ResolvedFile(media: null)],
    ]) {
      expect(
        matchRequestedFile(
          files,
          const PlayRequest(episode: 10, mediaId: media),
        ),
        isNull,
        reason: '$files',
      );
    }
  });

  // --- what gets recorded as a request ---

  test('picking an episode records it, and playing without one clears it', () {
    requestPlayback(episode: 10, mediaId: media);
    expect(playRequest.value?.episode, 10.0);
    expect(playRequest.value?.mediaId, media);

    // "continue watching" and autoplay name no episode: playback must choose
    // for itself again, rather than inheriting the last episode somebody
    // picked by hand
    requestPlayback(mediaId: media);
    expect(playRequest.value, isNull);
    requestPlayback();
    expect(playRequest.value, isNull);
  });

  test('an episode arriving as a string is recorded as a number, since that is what files match on', () {
    requestPlayback(episode: '24', mediaId: media);
    expect(playRequest.value?.episode, 24.0);
    expect(playRequest.value?.mediaId, media);
  });

  test('episode zero is a real request, not a missing one', () {
    requestPlayback(episode: 0, mediaId: media);
    expect(
      playRequest.value?.episode,
      0.0,
      reason:
          'shows with an episode 0 are why this cannot be a truthiness check',
    );
    expect(playRequest.value?.mediaId, media);
  });

  test('a request with no media still names its episode, for a magnet played on its own', () {
    requestPlayback(episode: 7);
    expect(playRequest.value?.episode, 7.0);
    expect(playRequest.value?.mediaId, isNull);
    expect(
      matchRequestedFile([file(6), file(7)], playRequest.value)?.media?.episode,
      7,
      reason: 'and it matches on episode alone',
    );
  });

  // --- refusing a release that cannot serve the request ---
  //
  // The player is the authority here: by this point every file has been through
  // the resolver, so episode numbers are in AniList's terms with season offsets
  // already applied. A release that still matches nothing provably cannot serve
  // the request, and playing its lowest episode instead is what made a two
  // episode fix release play 487 whatever was picked.

  /// [F-R] One Piece 0487+0490 v3, the release from the report.
  List<ResolvedFile> fixRelease() => [
    file(487, name: 'One Piece - 0487 v3 (WEB 1080p) [F-R].mkv'),
    file(490, name: 'One Piece - 0490 v3 (WEB 1080p) [F-R].mkv'),
  ];

  test('a two episode fix release refuses every other episode, naming what it holds', () {
    final missing = describeMissingEpisode(
      fixRelease(),
      const PlayRequest(episode: 10, mediaId: media),
    );
    expect(
      missing,
      isNotNull,
      reason: 'this is the play that used to silently start episode 487',
    );
    expect(
      missing,
      matches(RegExp(r'487.*490')),
      reason: 'the user is told what the release actually holds',
    );
    expect(missing, contains('not episode 10'));
    expect(
      missing,
      isNot(contains('487-490')),
      reason: 'a gap must not be described as a range, it holds neither 488 nor 489',
    );
  });

  test('the same release still plays the episodes it does hold', () {
    for (final episode in [487, 490]) {
      expect(
        describeMissingEpisode(
          fixRelease(),
          PlayRequest(episode: episode, mediaId: media),
        ),
        isNull,
        reason: 'episode $episode is right there',
      );
    }
  });

  test('a contiguous pack describes itself as a range', () {
    final pack = [for (var n = 459; n <= 516; n++) file(n)];
    expect(
      describeMissingEpisode(
        pack,
        const PlayRequest(episode: 23, mediaId: media),
      ),
      contains('episodes 459-516'),
    );
  });

  test('a single episode release says so in the singular', () {
    expect(
      describeMissingEpisode([
        file(12),
      ], const PlayRequest(episode: 3, mediaId: media)),
      contains('holds episode 12, not episode 3'),
    );
  });

  // the whole reason this check lives in the player rather than the debrid picker
  test('a release the resolver mapped onto the requested numbering is never refused', () {
    // files named 13-24 on disk, resolved to AniList episodes 1-12 of the
    // second season entry
    final cour = [
      for (var index = 0; index < 12; index++)
        ResolvedFile(
          name: 'Show - ${13 + index}.mkv',
          media: ResolvedFileMedia(
            mediaId: media,
            episode: index + 1,
            parsedEpisode: '${13 + index}',
          ),
        ),
    ];
    expect(
      describeMissingEpisode(
        cour,
        const PlayRequest(episode: 1, mediaId: media),
      ),
      isNull,
      reason: 'the resolver already applied the season offset',
    );
    expect(
      matchRequestedFile(
        cour,
        const PlayRequest(episode: 1, mediaId: media),
      )?.name,
      'Show - 13.mkv',
    );
  });

  // the Egghead case: a pack of episodes past 1000 played its lowest episode to
  // someone who asked for 28, because one unnumbered extra beside the episodes
  // used to switch the whole check off
  test(
    'an unnumbered extra beside the episodes does not disable the check',
    () {
      const unresolved = ResolvedFile(
        name: 'One Piece - Extras.mkv',
        media: ResolvedFileMedia(mediaId: media),
      );
      final pack = [for (var n = 1085; n < 1097; n++) file(n), unresolved];
      final missing = describeMissingEpisode(
        pack,
        const PlayRequest(episode: 28, mediaId: media),
      );
      expect(
        missing,
        isNotNull,
        reason: 'a pack of episode 1085 onwards must not play 1085 to someone who asked for 28',
      );
      expect(missing, contains('1085-1096'));
      expect(missing, contains('not episode 28'));
    },
  );

  test('a release nothing at all could be numbered in is still left alone', () {
    const unnamed = [
      ResolvedFile(
        name: 'One Piece - Extras.mkv',
        media: ResolvedFileMedia(mediaId: media),
      ),
      ResolvedFile(
        name: 'One Piece - More Extras.mkv',
        media: ResolvedFileMedia(mediaId: media),
      ),
    ];
    expect(
      describeMissingEpisode(
        unnamed,
        const PlayRequest(episode: 10, mediaId: media),
      ),
      isNull,
      reason: 'it says nothing about what it holds',
    );
  });

  test('a lone numbered file is judged like any other release', () {
    // "One Piece - 1021" is not episode 28, however few files the release has
    final single = [file(1021, name: 'One Piece - 1021 (1080p).mkv')];
    expect(
      describeMissingEpisode(
        single,
        const PlayRequest(episode: 28, mediaId: media),
      ),
      contains('holds episode 1021, not episode 28'),
    );
    expect(
      describeMissingEpisode(
        single,
        const PlayRequest(episode: 1021, mediaId: media),
      ),
      isNull,
    );
  });

  test('a movie, which carries no episode number at all, is never refused', () {
    const movie = [
      ResolvedFile(
        name: 'Show Movie [1080p].mkv',
        media: ResolvedFileMedia(mediaId: media),
      ),
    ];
    expect(
      describeMissingEpisode(
        movie,
        const PlayRequest(episode: 1, mediaId: media),
      ),
      isNull,
    );
  });

  test(
    'a release for another show entirely is left to the existing handling',
    () {
      final other = [file(1, mediaId: 999), file(2, mediaId: 999)];
      expect(
        describeMissingEpisode(
          other,
          const PlayRequest(episode: 10, mediaId: media),
        ),
        isNull,
        reason: "proving the wrong show is not this check's job",
      );
    },
  );

  test('a batched file covering the episode is not refused', () {
    const batched = [
      ResolvedFile(
        name: 'Show - 09-12.mkv',
        media: ResolvedFileMedia(
          mediaId: media,
          episodeRange: EpisodeRange(9, 12),
        ),
      ),
    ];
    expect(
      describeMissingEpisode(
        batched,
        const PlayRequest(episode: 11, mediaId: media),
      ),
      isNull,
    );
    expect(
      describeMissingEpisode(
        batched,
        const PlayRequest(episode: 20, mediaId: media),
      ),
      contains('episodes 9-12'),
      reason: 'and its range is described honestly',
    );
  });

  test('no request means nothing is ever refused', () {
    expect(describeMissingEpisode(fixRelease(), null), isNull);
    expect(
      describeMissingEpisode(
        [],
        const PlayRequest(episode: 10, mediaId: media),
      ),
      isNull,
    );
  });

  test('a scattered release lists what it holds without claiming the gaps', () {
    final scattered = [
      for (final n in [1, 5, 9, 13, 20, 30, 44]) file(n),
    ];
    final missing = describeMissingEpisode(
      scattered,
      const PlayRequest(episode: 2, mediaId: media),
    );
    expect(
      missing,
      contains('not every episode in between'),
      reason: 'seven scattered episodes must not read as 1-44',
    );
  });

  // Nothing above is specific to One Piece, to episode 487, or to debrid. Both
  // transports hand their files to the same player entry point, so this table
  // is the general guarantee: whatever the show, the numbering style or the
  // shape of the release, an explicit pick either plays exactly what was picked
  // or says why it cannot.
  test('any release, any show, any episode: the pick plays or the reason is given', () {
    final releases = <String, List<int>>{
      'a single episode release': [1],
      'a two episode fix release': [487, 490],
      'a cour': [for (var n = 1; n <= 12; n++) n],
      'a partial pack': [for (var n = 459; n <= 516; n++) n],
      'a full pack': [for (var n = 1; n <= 500; n++) n],
      'a pack with extras beside the episodes': [1, 2, 3],
      'a scattered fix release': [3, 17, 44],
    };
    for (final MapEntry(key: what, value: held) in releases.entries) {
      for (final mediaId in [21, 1535, 101922]) {
        // One Piece, Death Note, Demon Slayer
        final files = [
          for (final episode in held)
            file(
              episode,
              mediaId: mediaId,
              name: 'Show $mediaId - $episode.mkv',
            ),
        ];
        // everything it holds plays, exactly
        for (final episode in held) {
          expect(
            matchRequestedFile(
              files,
              PlayRequest(episode: episode, mediaId: mediaId),
            )?.media?.episode,
            episode,
            reason: '$what: episode $episode',
          );
          expect(
            describeMissingEpisode(
              files,
              PlayRequest(episode: episode, mediaId: mediaId),
            ),
            isNull,
            reason: '$what: episode $episode must not be refused',
          );
        }
        // and anything it does not hold is refused rather than substituted
        for (final episode in [
          0,
          999,
          held.first - 1,
          held.last + 1,
        ].where((candidate) => !held.contains(candidate))) {
          expect(
            matchRequestedFile(
              files,
              PlayRequest(episode: episode, mediaId: mediaId),
            ),
            isNull,
            reason: '$what: episode $episode must match nothing',
          );
          final missing = describeMissingEpisode(
            files,
            PlayRequest(episode: episode, mediaId: mediaId),
          );
          expect(
            missing,
            isNotNull,
            reason:
                '$what: episode $episode must be refused, not silently swapped',
          );
          expect(
            missing,
            matches(RegExp('not episode $episode\\b')),
            reason: '$what: the message names the episode asked for',
          );
        }
      }
    }
  });

  // the transports differ only in how many files reach the player, which this
  // check never reads
  test('the guarantee holds whether the files came from a torrent or a debrid window', () {
    final wholeTorrent = [for (var n = 1; n <= 100; n++) file(n)];
    final debridSlice = debridWindow(40);
    for (final (lane, files) in [
      ('torrent', wholeTorrent),
      ('debrid', debridSlice),
    ]) {
      expect(
        matchRequestedFile(
          files,
          const PlayRequest(episode: 40, mediaId: media),
        )?.media?.episode,
        40,
        reason: '$lane: plays what was picked',
      );
    }
    // a release that lacks the episode is refused on either lane
    final lacking = [file(487), file(490)];
    expect(
      describeMissingEpisode(
        lacking,
        const PlayRequest(episode: 40, mediaId: media),
      ),
      isNotNull,
      reason: 'refused whichever transport delivered it',
    );
  });
}
