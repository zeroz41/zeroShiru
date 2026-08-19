// Which releases are worth offering for an episode, judged from the release title before
// anything is played. Nothing here knows about transports: this runs over every source's search
// results, and the same answer decides what a torrent user and a debrid user are shown.
//
// The bug it was written for: `[F-R] One Piece 0487+0490` parses to ["0487", "0490"], which is
// the same shape a real batch like `One Piece 0001-0782` parses to, so the app read every array
// as "a batch, therefore it has everything". A two episode fix release was offered for every
// episode of the show, and picking any of them played 487.
import { test, beforeAll } from 'bun:test'
import assert from 'node:assert/strict'
import { releaseHoldsEpisode, releaseSpan } from '../../../common/modules/playback/coverage.js'

/** @type {(names: string[]) => Promise<any[]>} */
let anitomy
beforeAll(async () => {
  anitomy = (await import('anitomyscript')).default
})

const ONE_PIECE = 1139 // episodes the media has, which is what makes its numbering judgeable

/** Parses a real release title the way the search results pipeline does. */
async function parse (title) {
  const [parsed] = await anitomy([title])
  return parsed
}

const holds = (parsed, episode, opts = {}) => releaseHoldsEpisode(parsed, { episode, episodeCount: ONE_PIECE, ...opts })

test('a two episode fix release is offered for its own episodes and no others', async () => {
  const parsed = await parse('[F-R] One Piece 0487+0490 v3 (WEB 1080p)')
  assert.equal(holds(parsed, 487), true, 'it does hold 487')
  assert.equal(holds(parsed, 490), true, 'and 490')
  for (const episode of [1, 21, 23, 100, 486, 491, 1000]) {
    assert.equal(holds(parsed, episode), false, `episode ${episode} must not be offered this release`)
  }
})

test('a partial pack is offered only across the range it covers', async () => {
  const parsed = await parse('[F-R] One Piece - 459-516 v2 (WEB 1080p)')
  for (const episode of [459, 475, 500, 516]) assert.equal(holds(parsed, episode), true, `episode ${episode} is inside the pack`)
  for (const episode of [23, 458, 517, 1000]) assert.equal(holds(parsed, episode), false, `episode ${episode} is outside it`)
})

test('a real batch is still offered for everything inside it', async () => {
  const parsed = await parse('[F-R] One Piece 0001-0782 (Batch)')
  for (const episode of [1, 21, 487, 782]) assert.equal(holds(parsed, episode), true, `episode ${episode}`)
  assert.equal(holds(parsed, 900), false, 'but not past its end')
})

test('a single episode release is offered for that episode alone', async () => {
  const parsed = await parse('[SubsPlease] One Piece - 1021 (1080p) [ABCD1234].mkv')
  assert.equal(holds(parsed, 1021), true)
  assert.equal(holds(parsed, 21), false, 'the reported symptom in miniature: 1021 is not 21')
})

// everything below is why this hides so little: an unproven release is always kept
test('a title naming no episodes is never hidden', async () => {
  for (const title of ['[Group] One Piece Complete Series', '[Group] One Piece (BD 1080p) Dual Audio', '[Group] One Piece Season 1']) {
    assert.equal(holds(await parse(title), 21), true, title)
  }
})

test('an absolutely numbered release of a split cour is kept, since its numbering cannot be mapped', async () => {
  // AniList counts this season 1-12, the release counts it 13-24 from the start of the series
  const parsed = await parse('[Judas] Show S2 - 13-24 (BD 1080p)')
  assert.equal(releaseHoldsEpisode(parsed, { episode: 1, episodeCount: 12 }), true, 'numbered past the end of the season, so it is unjudgeable rather than wrong')
})

test('and once the absolute number is known, it is judged on that', async () => {
  const parsed = await parse('[Judas] Show S2 - 13-24 (BD 1080p)')
  assert.equal(releaseHoldsEpisode(parsed, { episode: 1, absoluteEpisode: 13, episodeCount: 12 }), true, 'episode 1 of the season is episode 13 of the series, which it holds')
  assert.equal(releaseHoldsEpisode(parsed, { episode: 1, absoluteEpisode: 25, episodeCount: 12 }), false, 'a season it does not hold is ruled out')
})

test('a show whose episode count is unknown is never judged', async () => {
  const parsed = await parse('[F-R] One Piece 0487+0490 v3 (WEB 1080p)')
  for (const episodeCount of [undefined, null, 0, NaN]) {
    assert.equal(releaseHoldsEpisode(parsed, { episode: 21, episodeCount }), true, `episodeCount ${episodeCount} leaves nothing to compare against`)
  }
})

test('a mis-parsed year or resolution cannot hide a release', async () => {
  // anitomy sometimes reads a stray number as the episode; a number past the end of the show
  // is treated as a numbering we do not understand rather than as proof
  assert.equal(releaseHoldsEpisode({ episode_number: '2024' }, { episode: 21, episodeCount: ONE_PIECE }), true)
  assert.equal(releaseHoldsEpisode({ episode_number: '1080' }, { episode: 21, episodeCount: 24 }), true)
})

test('nothing is judged when no episode was asked for, which is how batch browsing works', async () => {
  const parsed = await parse('[F-R] One Piece 0487+0490 v3 (WEB 1080p)')
  assert.equal(releaseHoldsEpisode(parsed, { episodeCount: ONE_PIECE }), true)
  assert.equal(releaseHoldsEpisode(parsed, {}), true)
  assert.equal(releaseHoldsEpisode(parsed), true)
})

test('malformed parses are kept rather than hidden', () => {
  for (const parseObject of [null, undefined, {}, { episode_number: [] }, { episode_number: 'v2' }, { episode_number: ['x', 'y'] }]) {
    assert.equal(releaseHoldsEpisode(parseObject, { episode: 21, episodeCount: ONE_PIECE }), true, JSON.stringify(parseObject))
  }
})

test('the span a title claims is read the same way for one number or many', () => {
  assert.deepEqual(releaseSpan('12'), { first: 12, last: 12 })
  assert.deepEqual(releaseSpan(['0487', '0490']), { first: 487, last: 490 })
  assert.deepEqual(releaseSpan(['516', '459']), { first: 459, last: 516 }, 'order in the title does not matter')
  assert.equal(releaseSpan(undefined), null)
  assert.equal(releaseSpan([]), null)
})

// the guarantee, across shows and numbering styles, for whichever transport ends up playing it
test('an episode search never lists a release whose own title rules it out', async () => {
  const catalogue = [
    { title: '[F-R] One Piece 0487+0490 v3 (WEB 1080p)', span: [487, 490] },
    { title: '[F-R] One Piece - 459-516 v2 (WEB 1080p)', span: [459, 516] },
    { title: '[SubsPlease] One Piece - 21 (1080p)', span: [21, 21] },
    { title: '[Group] One Piece 0001-0782 (Batch)', span: [1, 782] }
  ]
  for (const { title, span } of catalogue) {
    const parsed = await parse(title)
    for (const episode of [1, 21, 458, 487, 490, 500, 800]) {
      const offered = releaseHoldsEpisode(parsed, { episode, episodeCount: ONE_PIECE })
      assert.equal(offered, episode >= span[0] && episode <= span[1], `${title} offered for episode ${episode}`)
    }
  }
})

// --- when the search source invents the title ---
//
// SeaDex builds a result title as `[Group] ${animeTitle}${dualAudio ? ' Dual Audio' : ''}` for
// any release holding more than one file, throwing the real torrent name away. Two very
// different releases then arrive at the results list looking identical, and neither can be
// judged. The fix is not to guess harder here but to judge the real name, which the debrid
// service hands back for free while answering what it has cached.

test('an invented title is unjudgeable, which is why it used to be listed for every episode', async () => {
  const invented = await parse('[F-R] ONE PIECE Dual Audio')
  assert.equal(releaseSpan(invented.episode_number), null, 'nothing in this title says which episodes are inside')
  for (const episode of [1, 21, 28, 31, 487]) {
    assert.equal(holds(invented, episode), true, 'so it cannot be ruled out, however wrong it is')
  }
})

test('the real name behind that title decides it correctly', async () => {
  // exactly what TorBox returns from /torrents/checkcached for the same hash
  const real = await parse('[F-R] One Piece 0487+0490 v3 (WEB 1080p) [ UIndex.org ]')
  for (const episode of [21, 28, 29, 31]) {
    assert.equal(holds(real, episode), false, `episode ${episode} must be ruled out once the real name is known`)
  }
  assert.equal(holds(real, 487), true)
  assert.equal(holds(real, 490), true)
})

test('two releases an invented title made identical are told apart by their real names', async () => {
  // both arrive titled "[F-R] ONE PIECE Dual Audio"; only one holds episode 31
  const [fix, pack] = await anitomy([
    '[F-R] One Piece 0487+0490 v3 (WEB 1080p) [ UIndex.org ]',
    '[F-R] One Piece 0001-0782 (Batch)'
  ])
  assert.equal(holds(fix, 31), false, 'the two episode fix release goes')
  assert.equal(holds(pack, 31), true, 'the batch that really does hold episode 31 stays')
})
