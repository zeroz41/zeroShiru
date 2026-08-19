// Which file plays when the user named an episode. The player re-derives the episode from the
// resolved file list using watch status, which is right when playback chooses for itself and
// wrong when the user pointed at an episode. On debrid it was wrong by a fixed amount, because
// the resolved list is a window centred on the wanted episode: with a 12 file window the lowest
// episode present is the wanted one minus six, so picking episode 10 played 4 and picking 24
// played 18. These pin the request that now outranks that guess.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import DebridService from '../../../common/modules/debrid/service.js'
import TorBox from '../../../common/modules/debrid/torbox.js'
import { matchRequestedFile, describeMissingEpisode, requestPlayback, playRequest } from '../../../common/modules/playback/request.js'

const MEDIA = 21 // One Piece, as it happens

/** A resolved video file, shaped like the ones handleFiles works on. */
const file = (episode, { mediaId = MEDIA, name = `Show - ${episode}.mkv`, ...rest } = {}) => ({
  name,
  media: { media: { id: mediaId }, episode, parseObject: { episode_number: String(episode) }, ...rest }
})

/** The window a debrid resolve hands the player: maxFiles centred on the episode asked for. */
function debridWindow (episode, { first = 1, last = 100, maxFiles = TorBox.maxFiles } = {}) {
  const pack = Array.from({ length: last - first + 1 }, (_, index) => file(first + index))
  const target = pack.find(candidate => candidate.media.episode === episode)
  return DebridService.windowFiles(pack, target, maxFiles, candidate => candidate.name)
}

test('the episode the user asked for is what plays, not the lowest one in the window', () => {
  // the exact report: episode 10 played episode 4, episode 24 played 18
  for (const episode of [10, 24]) {
    const files = debridWindow(episode)
    assert.notEqual(files[0].media.episode, episode, 'sanity: the window really does start below the request')
    const played = matchRequestedFile(files, { episode, mediaId: MEDIA })
    assert.equal(played?.media.episode, episode, `asked for ${episode}, ${files[0].media.episode} is what used to play`)
  }
})

test('every episode of a window is reachable, wherever the window had to clamp', () => {
  for (const episode of [1, 2, 6, 7, 50, 99, 100]) {
    const files = debridWindow(episode)
    assert.equal(matchRequestedFile(files, { episode, mediaId: MEDIA })?.media.episode, episode, `episode ${episode}`)
  }
})

test('a full torrent pack plays the episode asked for rather than the first one', () => {
  // the same guess bites the torrent lane, it is just less visible there: the whole pack is
  // handed over, so the lowest episode present is episode 1
  const files = Array.from({ length: 100 }, (_, index) => file(index + 1))
  assert.equal(matchRequestedFile(files, { episode: 73, mediaId: MEDIA })?.media.episode, 73)
})

test('no request means playback still chooses for itself', () => {
  const files = [file(4), file(5)]
  assert.equal(matchRequestedFile(files, null), null, 'the watch-status heuristics must stay in charge')
  assert.equal(matchRequestedFile(files, undefined), null)
})

test('an episode the release does not hold falls back rather than playing something else', () => {
  const files = [file(4), file(5), file(6)]
  assert.equal(matchRequestedFile(files, { episode: 23, mediaId: MEDIA }), null, 'no match must not become "play file zero"')
})

test('another show\'s episode in a mixed batch is never what plays', () => {
  const files = [file(10, { mediaId: 999, name: 'Other Show - 10.mkv' }), file(10)]
  const played = matchRequestedFile(files, { episode: 10, mediaId: MEDIA })
  assert.equal(played?.media.media.id, MEDIA, 'the requested media decides between same-numbered episodes')
})

test('a file whose media never resolved is still eligible for the release being played', () => {
  const unresolved = { name: 'Show - 10.mkv', media: { episode: 10, parseObject: { episode_number: '10' } } }
  assert.equal(matchRequestedFile([file(9), unresolved], { episode: 10, mediaId: MEDIA }), unresolved, 'it belongs to the release the user just asked to play')
})

test('episode numbers match whether they arrive as numbers or strings', () => {
  const files = [file('09'), file('10'), file('11')]
  assert.equal(matchRequestedFile(files, { episode: 10, mediaId: MEDIA })?.media.episode, '10')
  assert.equal(matchRequestedFile(files, { episode: '10', mediaId: MEDIA })?.media.episode, '10')
})

test('the parsed episode number is used when the resolver left no episode of its own', () => {
  const parsedOnly = { name: 'Show - 10.mkv', media: { media: { id: MEDIA }, parseObject: { episode_number: '10' } } }
  assert.equal(matchRequestedFile([file(9), parsedOnly], { episode: 10, mediaId: MEDIA }), parsedOnly)
})

test('a file holding several episodes serves any episode inside its range', () => {
  const batched = { name: 'Show - 09-12.mkv', media: { media: { id: MEDIA }, episodeRange: { first: 9, last: 12 } } }
  const files = [file(1), batched]
  assert.equal(matchRequestedFile(files, { episode: 11, mediaId: MEDIA }), batched)
  assert.equal(matchRequestedFile(files, { episode: 13, mediaId: MEDIA }), null, 'and nothing outside it')
})

test('an exact episode beats a range that merely contains it', () => {
  const batched = { name: 'Show - 09-12.mkv', media: { media: { id: MEDIA }, episodeRange: { first: 9, last: 12 } } }
  const exact = file(11)
  assert.equal(matchRequestedFile([batched, exact], { episode: 11, mediaId: MEDIA }), exact)
})

test('an empty or malformed file list is handled without throwing', () => {
  for (const files of [[], null, undefined, [{}], [{ media: null }]]) {
    assert.equal(matchRequestedFile(files, { episode: 10, mediaId: MEDIA }), null, JSON.stringify(files))
  }
})

// --- what gets recorded as a request ---

test('picking an episode records it, and playing without one clears it', () => {
  requestPlayback({ media: { id: MEDIA }, episode: 10 })
  assert.deepEqual(playRequest.value, { episode: 10, mediaId: MEDIA })

  // "continue watching" and autoplay name no episode: playback must choose for itself again,
  // rather than inheriting the last episode somebody picked by hand
  requestPlayback({ media: { id: MEDIA } })
  assert.equal(playRequest.value, null)
  requestPlayback(undefined)
  assert.equal(playRequest.value, null)
})

test('an episode arriving as a string is recorded as a number, since that is what files match on', () => {
  requestPlayback({ media: { id: MEDIA }, episode: '24' })
  assert.deepEqual(playRequest.value, { episode: 24, mediaId: MEDIA })
})

test('episode zero is a real request, not a missing one', () => {
  requestPlayback({ media: { id: MEDIA }, episode: 0 })
  assert.deepEqual(playRequest.value, { episode: 0, mediaId: MEDIA }, 'shows with an episode 0 are why this cannot be a truthiness check')
})

test('a request with no media still names its episode, for a magnet played on its own', () => {
  requestPlayback({ episode: 7 })
  assert.deepEqual(playRequest.value, { episode: 7, mediaId: undefined })
  assert.equal(matchRequestedFile([file(6), file(7)], playRequest.value)?.media.episode, 7, 'and it matches on episode alone')
})

// --- refusing a release that cannot serve the request ---
//
// The player is the authority here: by this point every file has been through AnimeResolver, so
// episode numbers are in AniList's terms with season offsets already applied. A release that
// still matches nothing provably cannot serve the request, and playing its lowest episode
// instead is what made a two episode fix release play 487 whatever was picked.

/** [F-R] One Piece 0487+0490 v3, the release from the report. */
const fixRelease = () => [file(487, { name: 'One Piece - 0487 v3 (WEB 1080p) [F-R].mkv' }), file(490, { name: 'One Piece - 0490 v3 (WEB 1080p) [F-R].mkv' })]

test('a two episode fix release refuses every other episode, naming what it holds', () => {
  const missing = describeMissingEpisode(fixRelease(), { episode: 10, mediaId: MEDIA })
  assert.ok(missing, 'this is the play that used to silently start episode 487')
  assert.match(missing, /487.*490/, 'the user is told what the release actually holds')
  assert.match(missing, /not episode 10/)
  assert.doesNotMatch(missing, /487-490/, 'a gap must not be described as a range, it holds neither 488 nor 489')
})

test('the same release still plays the episodes it does hold', () => {
  for (const episode of [487, 490]) {
    assert.equal(describeMissingEpisode(fixRelease(), { episode, mediaId: MEDIA }), null, `episode ${episode} is right there`)
  }
})

test('a contiguous pack describes itself as a range', () => {
  const pack = Array.from({ length: 58 }, (_, index) => file(459 + index))
  assert.match(describeMissingEpisode(pack, { episode: 23, mediaId: MEDIA }), /episodes 459-516/)
})

test('a single episode release says so in the singular', () => {
  assert.match(describeMissingEpisode([file(12)], { episode: 3, mediaId: MEDIA }), /holds episode 12, not episode 3/)
})

// the whole reason this check lives in the player rather than the debrid picker
test('a release the resolver mapped onto the requested numbering is never refused', () => {
  // files named 13-24 on disk, resolved to AniList episodes 1-12 of the second season entry
  const cour = Array.from({ length: 12 }, (_, index) => ({
    name: `Show - ${13 + index}.mkv`,
    media: { media: { id: MEDIA }, episode: index + 1, parseObject: { episode_number: String(13 + index) } }
  }))
  assert.equal(describeMissingEpisode(cour, { episode: 1, mediaId: MEDIA }), null, 'the resolver already applied the season offset')
  assert.equal(matchRequestedFile(cour, { episode: 1, mediaId: MEDIA })?.name, 'Show - 13.mkv')
})

// the Egghead case: a pack of episodes past 1000 played its lowest episode to someone who asked
// for 28, because one unnumbered extra beside the episodes used to switch the whole check off
test('an unnumbered extra beside the episodes does not disable the check', () => {
  const unresolved = { name: 'One Piece - Extras.mkv', media: { media: { id: MEDIA } } }
  const pack = [...Array.from({ length: 12 }, (_, index) => file(1085 + index)), unresolved]
  const missing = describeMissingEpisode(pack, { episode: 28, mediaId: MEDIA })
  assert.ok(missing, 'a pack of episode 1085 onwards must not play 1085 to someone who asked for 28')
  assert.match(missing, /1085-1096/)
  assert.match(missing, /not episode 28/)
})

test('a release nothing at all could be numbered in is still left alone', () => {
  const unnamed = [
    { name: 'One Piece - Extras.mkv', media: { media: { id: MEDIA } } },
    { name: 'One Piece - More Extras.mkv', media: { media: { id: MEDIA } } }
  ]
  assert.equal(describeMissingEpisode(unnamed, { episode: 10, mediaId: MEDIA }), null, 'it says nothing about what it holds')
})

test('a lone numbered file is judged like any other release', () => {
  // "One Piece - 1021" is not episode 28, however few files the release has
  const single = [file(1021, { name: 'One Piece - 1021 (1080p).mkv' })]
  assert.match(describeMissingEpisode(single, { episode: 28, mediaId: MEDIA }), /holds episode 1021, not episode 28/)
  assert.equal(describeMissingEpisode(single, { episode: 1021, mediaId: MEDIA }), null)
})

test('a movie, which carries no episode number at all, is never refused', () => {
  const movie = [{ name: 'Show Movie [1080p].mkv', media: { media: { id: MEDIA }, parseObject: {} } }]
  assert.equal(describeMissingEpisode(movie, { episode: 1, mediaId: MEDIA }), null)
})

test('a release for another show entirely is left to the existing handling', () => {
  const other = [file(1, { mediaId: 999 }), file(2, { mediaId: 999 })]
  assert.equal(describeMissingEpisode(other, { episode: 10, mediaId: MEDIA }), null, 'proving the wrong show is not this check\'s job')
})

test('a batched file covering the episode is not refused', () => {
  const batched = [{ name: 'Show - 09-12.mkv', media: { media: { id: MEDIA }, episodeRange: { first: 9, last: 12 } } }]
  assert.equal(describeMissingEpisode(batched, { episode: 11, mediaId: MEDIA }), null)
  assert.match(describeMissingEpisode(batched, { episode: 20, mediaId: MEDIA }), /episodes 9-12/, 'and its range is described honestly')
})

test('no request means nothing is ever refused', () => {
  assert.equal(describeMissingEpisode(fixRelease(), null), null)
  assert.equal(describeMissingEpisode([], { episode: 10, mediaId: MEDIA }), null)
})

test('a scattered release lists what it holds without claiming the gaps', () => {
  const scattered = [file(1), file(5), file(9), file(13), file(20), file(30), file(44)]
  const missing = describeMissingEpisode(scattered, { episode: 2, mediaId: MEDIA })
  assert.match(missing, /not every episode in between/, 'seven scattered episodes must not read as 1-44')
})

// Nothing above is specific to One Piece, to episode 487, or to debrid. Both transports hand
// their files to the same `handleFiles`, so this table is the general guarantee: whatever the
// show, the numbering style or the shape of the release, an explicit pick either plays exactly
// what was picked or says why it cannot.
const RELEASES = [
  { what: 'a single episode release', held: [1], shape: episodes => episodes },
  { what: 'a two episode fix release', held: [487, 490], shape: episodes => episodes },
  { what: 'a cour', held: Array.from({ length: 12 }, (_, index) => index + 1), shape: episodes => episodes },
  { what: 'a partial pack', held: Array.from({ length: 58 }, (_, index) => 459 + index), shape: episodes => episodes },
  { what: 'a full pack', held: Array.from({ length: 500 }, (_, index) => index + 1), shape: episodes => episodes },
  { what: 'a pack with extras beside the episodes', held: [1, 2, 3], shape: episodes => episodes },
  { what: 'a scattered fix release', held: [3, 17, 44], shape: episodes => episodes }
]

test('any release, any show, any episode: the pick plays or the reason is given', () => {
  for (const { what, held } of RELEASES) {
    for (const mediaId of [21, 1535, 101922]) { // One Piece, Death Note, Demon Slayer
      const files = held.map(episode => file(episode, { mediaId, name: `Show ${mediaId} - ${episode}.mkv` }))
      // everything it holds plays, exactly
      for (const episode of held) {
        assert.equal(matchRequestedFile(files, { episode, mediaId })?.media.episode, episode, `${what}: episode ${episode}`)
        assert.equal(describeMissingEpisode(files, { episode, mediaId }), null, `${what}: episode ${episode} must not be refused`)
      }
      // and anything it does not hold is refused rather than substituted
      for (const episode of [0, 999, held[0] - 1, held[held.length - 1] + 1].filter(candidate => !held.includes(candidate))) {
        assert.equal(matchRequestedFile(files, { episode, mediaId }), null, `${what}: episode ${episode} must match nothing`)
        const missing = describeMissingEpisode(files, { episode, mediaId })
        assert.ok(missing, `${what}: episode ${episode} must be refused, not silently swapped`)
        assert.match(missing, new RegExp(`not episode ${episode}\\b`), `${what}: the message names the episode asked for`)
      }
    }
  }
})

// the transports differ only in how many files reach the player, which this check never reads
test('the guarantee holds whether the files came from a torrent or a debrid window', () => {
  const pack = Array.from({ length: 100 }, (_, index) => file(index + 1))
  const wholeTorrent = pack
  const debridSlice = debridWindow(40)
  for (const [lane, files] of [['torrent', wholeTorrent], ['debrid', debridSlice]]) {
    assert.equal(matchRequestedFile(files, { episode: 40, mediaId: MEDIA })?.media.episode, 40, `${lane}: plays what was picked`)
  }
  // a release that lacks the episode is refused on either lane
  const lacking = [file(487), file(490)]
  assert.ok(describeMissingEpisode(lacking, { episode: 40, mediaId: MEDIA }), 'refused whichever transport delivered it')
})
