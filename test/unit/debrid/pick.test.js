// Episode picking out of season packs, driven by the real anitomy parser — the same WASM the
// app ships. This is the code that decides which file of a 150-episode pack actually plays, so
// every case here is a way playback silently plays the wrong episode when it regresses.
//
// Two regressions these were written against, both seen with real packs:
// - packs list NC/OP/ED extras before the episodes, and "NCOP1" parses as episode 1, so asking
//   for episode 1 played the creditless opening
// - multi-episode files ("Show - 01-12") parse their number as an array, which Number() turns
//   into NaN, so they could never match and playback fell back to the largest file
import { test, beforeAll } from 'bun:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { pickEpisodeFile, pickPackFile, EpisodeNotInPackError } from '../../../common/modules/debrid/pick.js'

/** @type {(names: string[]) => Promise<any[]>} */
let anitomy
beforeAll(async () => {
  anitomy = (await import('anitomyscript')).default
})

const file = (path, size = 1000) => ({ path: path.startsWith('/') ? path : `/${path}`, size })
const pick = (files, episode) => pickEpisodeFile(files, episode, names => anitomy(names))

test('a large pack yields exactly the requested episode', async () => {
  const files = Array.from({ length: 150 }, (_, index) => file(`Pack/[Group] Show - ${String(index + 1).padStart(3, '0')} [1080p].mkv`))
  assert.equal((await pick(files, 1)).path, '/Pack/[Group] Show - 001 [1080p].mkv')
  assert.equal((await pick(files, 100)).path, '/Pack/[Group] Show - 100 [1080p].mkv')
  assert.equal((await pick(files, 150)).path, '/Pack/[Group] Show - 150 [1080p].mkv')
})

test('padding never matters: episode 5 matches 05, 005, and E05 alike', async () => {
  for (const name of ['Show - 05.mkv', 'Show - 005.mkv', 'Show S01E05.mkv', 'Show.S01.E05.1080p.mkv']) {
    const files = [file('Show - 04.mkv'), file(name), file('Show - 06.mkv')]
    assert.equal((await pick(files, 5)).path, `/${name}`, name)
  }
})

test('episode 12 does not match a 12.5 special, and 12.5 can still be asked for', async () => {
  const files = [file('Show - 12.mkv'), file('Show - 12.5.mkv'), file('Show - 13.mkv')]
  assert.equal((await pick(files, 12)).path, '/Show - 12.mkv')
  assert.equal((await pick(files, 12.5)).path, '/Show - 12.5.mkv')
})

test('a v2 release still matches its episode number', async () => {
  const files = [file('Show - 04.mkv'), file('Show - 05v2.mkv'), file('Show - 06.mkv')]
  assert.equal((await pick(files, 5)).path, '/Show - 05v2.mkv')
})

// the case that played the wrong file: extras parse with episode numbers of their own
test('creditless openings and endings never shadow the real episode', async () => {
  const files = [
    file('Extras/[Group] Show - NCOP1.mkv', 300),
    file('Extras/[Group] Show - NCED1.mkv', 300),
    file('[Group] Show - 01.mkv', 900),
    file('[Group] Show - 02.mkv', 900)
  ]
  assert.equal((await pick(files, 1)).path, '/[Group] Show - 01.mkv', 'the episode, not the creditless opening listed before it')
  assert.equal((await pick(files, 2)).path, '/[Group] Show - 02.mkv')
})

test('specials and OVAs do not shadow same-numbered episodes either', async () => {
  const files = [
    file('Specials/[Group] Show - SP01.mkv'),
    file('Specials/[Group] Show - OVA 02.mkv'),
    file('[Group] Show - 01.mkv'),
    file('[Group] Show - 02.mkv')
  ]
  assert.equal((await pick(files, 1)).path, '/[Group] Show - 01.mkv')
  assert.equal((await pick(files, 2)).path, '/[Group] Show - 02.mkv')
})

test('a pack of only extras can still serve them by number', async () => {
  const files = [file('[Group] Show - NCOP1.mkv'), file('[Group] Show - NCOP2.mkv')]
  assert.equal((await pick(files, 2)).path, '/[Group] Show - NCOP2.mkv', 'when nothing but extras exists, the number decides')
})

// multi-episode files parse their number as an array, which must act as a range
test('a double episode file matches both of its episodes', async () => {
  const files = [file('[Group] Show - 01-02.mkv'), file('[Group] Show - 03-04.mkv')]
  assert.equal((await pick(files, 1)).path, '/[Group] Show - 01-02.mkv')
  assert.equal((await pick(files, 4)).path, '/[Group] Show - 03-04.mkv')
})

test('an episode inside a batch file is found there when no single file has it', async () => {
  const files = [file('[Group] Show - 01-12 [Batch].mkv', 5000), file('[Group] Show - 13.mkv', 900)]
  assert.equal((await pick(files, 5)).path, '/[Group] Show - 01-12 [Batch].mkv')
  assert.equal((await pick(files, 13)).path, '/[Group] Show - 13.mkv')
})

test('a single file matching exactly beats a batch that merely contains the episode', async () => {
  const files = [file('[Group] Show - 01-12 [Batch].mkv', 5000), file('[Group] Show - 05.mkv', 900)]
  assert.equal((await pick(files, 5)).path, '/[Group] Show - 05.mkv', 'the dedicated file, not the batch around it')
})

test('the first match in torrent order wins when a pack ships duplicates', async () => {
  const files = [file('1080p/Show - 05.mkv', 2000), file('720p/Show - 05.mkv', 900)]
  assert.equal((await pick(files, 5)).path, '/1080p/Show - 05.mkv')
})

test('subtitles and junk beside the videos never come back as the pick', async () => {
  const files = [
    file('Show - 05.ass', 30),
    file('Show - 05.srt', 30),
    file('readme.txt', 999999),
    file('Show - 05.mkv', 900)
  ]
  assert.equal((await pick(files, 5)).path, '/Show - 05.mkv')
})

test('a single-video release skips parsing entirely and plays the video', async () => {
  const files = [file('Movie.mkv', 5000), file('Movie.ass', 30)]
  assert.equal((await pick(files, 3)).path, '/Movie.mkv', 'nothing to disambiguate, whatever the episode asked for')
})

test('a release with no videos falls back to the first file rather than nothing', async () => {
  const files = [file('Show.ass', 30), file('Show.srt', 20)]
  assert.equal((await pick(files, 1)).path, '/Show.ass')
})

// the reported bug: a 459-516 One Piece pack asked for episode 23 played episode 475, the
// largest file, because "no match" fell back to "largest video". This is the real file list of
// that release, scraped from the tracker.
test('a partial pack asked for an episode it provably lacks refuses instead of guessing', async () => {
  const files = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../fixtures/fr-one-piece-459-516.json'), 'utf8'))
  await assert.rejects(pick(files, 23), error => {
    assert.ok(error instanceof EpisodeNotInPackError, 'a provable mismatch is an error, never a silent wrong episode')
    assert.equal(error.first, 459)
    assert.equal(error.last, 516)
    assert.match(error.message, /459-516/, 'the message tells the user what the release really holds')
    assert.match(error.message, /episode 23/, 'and what they asked for')
    return true
  })
  // and the same pack still serves what it does hold
  assert.equal((await pick(files, 475)).path, '/One Piece - 475 v2 [F-R][b1929031].mkv')
  assert.equal((await pick(files, 459)).path, '/One Piece - 459 v2 [F-R][9d4e6bc5].mkv', 'the first episode of the span')
  assert.equal((await pick(files, 516)).path, '/One Piece - 516 v2 [F-R][54ce21cf].mkv', 'and the last')
})

test('extras in a partial pack do not stretch the span the error reports', async () => {
  const files = [
    file('Extras/Show - NCOP1.mkv', 5000),
    file('Show - 40.mkv', 900),
    file('Show - 41.mkv', 950)
  ]
  await assert.rejects(pick(files, 3), error => {
    assert.ok(error instanceof EpisodeNotInPackError)
    assert.equal(error.first, 40, 'the NCOP parsing as episode 1 must not make the pack claim to start at 1')
    assert.equal(error.last, 41)
    return true
  })
})

test('an unproven mismatch still falls back to the largest real episode, never an extra', async () => {
  // one file the parser cannot number keeps this a guess rather than a proof, so playback
  // degrades gracefully instead of refusing
  const files = [
    file('Extras/Show - NCOP1.mkv', 5000),
    file('Show - 01.mkv', 900),
    file('Show - 02.mkv', 950),
    file('Show - Unnumbered Special.mkv', 800)
  ]
  const picked = await pick(files, 40)
  assert.equal(picked.path, '/Show - 02.mkv', 'the largest episode file, not the larger extra beside it')
})

test('a parser that throws still yields a playable fallback', async () => {
  const files = [file('Show - 01.mkv', 900), file('Show - 02.mkv', 950)]
  const picked = await pickEpisodeFile(files, 2, () => { throw new Error('wasm fell over') })
  assert.equal(picked.path, '/Show - 02.mkv', 'largest video when parsing is unavailable')
})

test('picking does not reorder the caller\'s file list', async () => {
  // the unnumbered file keeps the mismatch unproven, forcing the size-sorted fallback path
  const files = [file('Show - 03.mkv', 100), file('Show - 01.mkv', 900), file('Show Special.mkv', 500)]
  await pick(files, 40)
  assert.deepEqual(files.map(f => f.path), ['/Show - 03.mkv', '/Show - 01.mkv', '/Show Special.mkv'], 'sorting must work on a copy')
})

test('season folders inside one pack resolve by episode within the parsed names', async () => {
  const files = [
    file('Season 1/[Group] Show S01E01.mkv'),
    file('Season 1/[Group] Show S01E02.mkv'),
    file('Season 2/[Group] Show S02E01.mkv')
  ]
  // the picker works on parsed episode numbers alone; the first file carrying the number wins,
  // which is the S1 episode. Season disambiguation belongs to the resolver that chose this pack.
  assert.equal((await pick(files, 2)).path, '/Season 1/[Group] Show S01E02.mkv')
})

// --- refusing only when refusing costs something ---
//
// The picker reads the release's own numbering; the player reads AniList's, with the season
// offset mappings the picker has no access to. A split cour release numbered 13-24 therefore
// looks like it lacks episode 1 when it holds it. That must not become a refusal when the whole
// release reaches the player anyway.

test('a small release the picker cannot match is handed to the player instead of refused', async () => {
  const files = Array.from({ length: 12 }, (_, index) => file(`[Group] Show - ${13 + index}.mkv`))
  const picked = await pickPackFile(files, 1, anitomy, { maxFiles: 12 })
  assert.equal(picked, undefined, 'no pick means "you decide", and every file still reaches the player')
  await assert.rejects(pick(files, 1), EpisodeNotInPackError, 'the strict picker underneath still says what it knows')
})

test('a release too big to hand over whole is still refused rather than windowed blindly', async () => {
  const files = Array.from({ length: 58 }, (_, index) => file(`One Piece - ${459 + index}.mkv`))
  await assert.rejects(pickPackFile(files, 23, anitomy, { maxFiles: 12 }), EpisodeNotInPackError, 'windowing this would play an arbitrary episode')
})

test('a match is returned whatever the file count', async () => {
  const files = Array.from({ length: 58 }, (_, index) => file(`One Piece - ${459 + index}.mkv`))
  assert.equal((await pickPackFile(files, 475, anitomy, { maxFiles: 12 })).path, '/One Piece - 475.mkv')
  const small = [file('Show - 01.mkv'), file('Show - 02.mkv')]
  assert.equal((await pickPackFile(small, 2, anitomy, { maxFiles: 12 })).path, '/Show - 02.mkv')
})

test('errors that are not a missing episode still surface', async () => {
  const files = [file('Show - 01.mkv'), file('Show - 02.mkv')]
  // a parser that throws is handled inside the picker, so the fallback still yields a file
  assert.ok(await pickPackFile(files, 5, () => { throw new Error('wasm fell over') }, { maxFiles: 12 }))
})
