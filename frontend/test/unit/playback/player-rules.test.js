// The player's own rules, pulled out of PlayerPage.svelte so they can be tested at all.
// Each answers a bug the user hit: switching audio track silenced everything, the
// loading spinner stuck forever, and thumbnail drawing raced the stream it was drawn from.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { audioSelectionWrites, safeGain, storedVolume, describeTracks, needsPipelineRebuild, runsOnRebuild, heldPlayback } from '../../../common/modules/playback/audio.js'
import { showsSpinner } from '../../../common/modules/playback/buffering.js'
import { thumbnailHorizon, THUMBNAIL_LOOKAHEAD_SECONDS } from '../../../common/modules/playback/thumbnails.js'
import { mediaErrorReport, stillFailing } from '../../../common/modules/playback/errors.js'
import { watchesForStall, loadProgressMark, advanceStall, reloadPlan, STALL_PATIENCE_MS, STALL_RELOADS } from '../../../common/modules/playback/stall.js'
import { savesProgress } from '../../../common/modules/playback/resume.js'
import { episodePrompt } from '../../../common/modules/playback/prompts.js'

const tracks = [{ id: 'jpn' }, { id: 'eng' }, { id: 'spa' }]

test('the wanted audio track is enabled before any other is turned off', () => {
  const writes = audioSelectionWrites(tracks, 'spa')
  assert.deepEqual(writes[0], { id: 'spa', enabled: true }, 'an instant with nothing selected is what silenced the element')
  assert.deepEqual(writes.slice(1), [{ id: 'jpn', enabled: false }, { id: 'eng', enabled: false }])
  // and at no point in the sequence is every track off
  let enabled = new Set(['jpn'])
  for (const write of writes) {
    write.enabled ? enabled.add(write.id) : enabled.delete(write.id)
    assert.ok(enabled.size > 0, `nothing is selected after writing ${write.id}=${write.enabled}`)
  }
  assert.deepEqual([...enabled], ['spa'])
})

test('switching to the track that is already playing still ends with it enabled', () => {
  assert.deepEqual(audioSelectionWrites(tracks, 'jpn')[0], { id: 'jpn', enabled: true })
})

test('a track that is not there is not worth muting everything for', () => {
  assert.deepEqual(audioSelectionWrites(tracks, 'fre'), [])
  assert.deepEqual(audioSelectionWrites([], 'jpn'), [])
  assert.deepEqual(audioSelectionWrites(null, 'jpn'), [])
})

test('a remembered boost with no usable amount is no boost, never silence', () => {
  assert.equal(safeGain(0), 1, 'zero gain is silence the volume slider cannot undo')
  assert.equal(safeGain(undefined), 1)
  assert.equal(safeGain(null), 1)
  assert.equal(safeGain(NaN), 1)
  assert.equal(safeGain(-2), 1)
  assert.equal(safeGain('nonsense'), 1)
  assert.equal(safeGain(2.5), 2.5, 'and a real boost is still restored')
  assert.equal(safeGain('1.5'), 1.5)
})

test('the spinner asks the element, and a stray waiting event cannot force it', () => {
  // the bug: `on:waiting={showBuffering}` handed the DOM event in as "skip the check"
  assert.equal(showsSpinner({ readyState: 4 }), false, 'an element that can play is not buffering')
  assert.equal(showsSpinner({ readyState: 3 }), false)
  assert.equal(showsSpinner({ readyState: 2 }), true, 'and one that has run out of data is')
  assert.equal(showsSpinner({ forced: {}, readyState: 4 }), false, 'only a real boolean forces it')
  assert.equal(showsSpinner({ forced: true, readyState: 4 }), true)
})

test('an external player answers for itself', () => {
  assert.equal(showsSpinner({ externalPlayback: true, externalPlayerReady: false, readyState: 4 }), true)
  assert.equal(showsSpinner({ externalPlayback: true, externalPlayerReady: true, readyState: 0 }), false)
  assert.equal(showsSpinner({ externalPlayback: true, externalPlayerReady: true, forced: true }), false)
})

test('thumbnails on a torrent only cover what has been downloaded', () => {
  assert.equal(thumbnailHorizon({ duration: 1_000, bufferPercent: 40, currentTime: 0 }), 400)
  assert.equal(thumbnailHorizon({ duration: 1_000, bufferPercent: 0, currentTime: 900 }), 0, 'nothing downloaded is nothing to draw')
})

test('thumbnails on a reachable file stay near the playhead instead of racing the stream', () => {
  const early = thumbnailHorizon({ duration: 10_000, currentTime: 0, reachable: true })
  assert.equal(early, THUMBNAIL_LOOKAHEAD_SECONDS, 'scrubbing the whole file at once starved the player it was drawn from')
  assert.equal(thumbnailHorizon({ duration: 10_000, currentTime: 1_200, reachable: true }), 1_200 + THUMBNAIL_LOOKAHEAD_SECONDS)
  assert.equal(thumbnailHorizon({ duration: 600, currentTime: 500, reachable: true }), 600, 'and never past the end of the file')
})

test('an unknown duration is not a horizon of zero', () => {
  // zero would read as "done", and the thumbnails would silently never be drawn
  assert.ok(Number.isNaN(thumbnailHorizon({ duration: NaN, reachable: true })))
  assert.ok(Number.isNaN(thumbnailHorizon({ duration: 0, bufferPercent: 100 })))
  assert.ok(Number.isNaN(thumbnailHorizon({ duration: Infinity, currentTime: 10, reachable: true })))
})

test('a volume read back from settings is a number, whatever was stored', () => {
  // it is persisted as a string, and the scroll wheel adds to it: "0.5" + -0.05 is
  // "0.5-0.05", which is NaN, which was then stored as the title's boost
  assert.equal(storedVolume('0.5'), 0.5)
  assert.equal(storedVolume('0'), 0, 'a muted player stays muted')
  assert.equal(storedVolume(1), 1)
  assert.equal(storedVolume(undefined), 1)
  assert.equal(storedVolume('nonsense'), 1)
  assert.equal(storedVolume(-1), 1)
  assert.equal(storedVolume('3'), 1, 'the element only takes 0 to 1; the boost above that is a gain node')
})

// --- what an error from the video element is worth saying out loud ---

test('a load of nothing is not a failed video', () => {
  // starting a file tears the last one down by clearing the source, and the element
  // calls that a failed load: one bogus "unsupported codec" toast per episode
  assert.equal(mediaErrorReport({ code: 4, src: null }), null)
  assert.equal(mediaErrorReport({ code: 4, src: '' }), null)
  assert.equal(mediaErrorReport({ code: 0, src: 'https://cdn/a.mkv' }), null)
  assert.equal(mediaErrorReport({}), null)
})

test('an abort is something the player did to itself', () => {
  assert.equal(mediaErrorReport({ code: 1, src: 'https://cdn/a.mkv' }), null)
})

test('network and decode failures are reported at once, a source failure waits to be proven', () => {
  assert.deepEqual(mediaErrorReport({ code: 2, src: 'https://cdn/a.mkv' }), { kind: 'network', confirm: false })
  assert.deepEqual(mediaErrorReport({ code: 3, src: 'https://cdn/a.mkv' }), { kind: 'decode', confirm: false })
  assert.deepEqual(mediaErrorReport({ code: 4, src: 'https://cdn/a.mkv' }), { kind: 'source', confirm: true })
})

test('a source that went on to play is not reported at all', () => {
  const src = 'https://cdn/a.mkv'
  assert.equal(stillFailing({ erroredSrc: src, currentSrc: src, readyState: 4 }), false, 'it played, whatever it said first')
  assert.equal(stillFailing({ erroredSrc: src, currentSrc: src, readyState: 2 }), false)
  assert.equal(stillFailing({ erroredSrc: src, currentSrc: 'https://cdn/b.mkv', readyState: 0 }), false, 'a different file now, so the old failure is moot')
  assert.equal(stillFailing({ erroredSrc: null, currentSrc: src, readyState: 0 }), false)
})

test('a source that never got anywhere is still a failure', () => {
  const src = 'https://cdn/broken.mkv'
  assert.equal(stillFailing({ erroredSrc: src, currentSrc: src, readyState: 0 }), true)
  assert.equal(stillFailing({ erroredSrc: src, currentSrc: src }), true)
})

test('advancing playback takes the spinner down, whatever readyState claims', () => {
  // on debrid range streams this webview has reported starvation over a video that
  // was visibly playing; position moving forward is the element's own confession
  assert.equal(showsSpinner({ readyState: 2, advanced: true }), false)
  assert.equal(showsSpinner({ readyState: 2, advanced: false }), true)
  // but a forced spinner (file being swapped) outranks it, and only real booleans count
  assert.equal(showsSpinner({ forced: true, readyState: 4, advanced: true }), true)
  assert.equal(showsSpinner({ readyState: 2, advanced: {} }), true)
})

// --- switching audio track without stopping the player ---

test('a track switch before playback is just the flags; mid-play it is a rebuild', () => {
  assert.equal(needsPipelineRebuild({ readyState: 0, currentTime: 0 }), false, 'no pipeline yet, the flags go in with it')
  assert.equal(needsPipelineRebuild({ readyState: 1, currentTime: 0 }), false, 'checkAudio picks the preferred track here, at loadedmetadata')
  assert.equal(needsPipelineRebuild({ readyState: 4, currentTime: 0.4 }), false)
  assert.equal(needsPipelineRebuild({ readyState: 1, currentTime: 10.31 }), true, 'the log line that proved in-place reselection comes back silent')
  assert.equal(needsPipelineRebuild({ readyState: 4, currentTime: NaN }), false, 'a position nobody knows is not a mid-play switch')
})

test('a rebuild under the same file re-runs nothing that belongs to a new file', () => {
  // each of these was a cost the user could see: a jump back to the last saved position,
  // a second stream scrubbing the same link, the preferred language overriding the pick
  for (const step of ['resume', 'thumbnails', 'audio', 'autoplay', 'chapters', 'subtitles']) {
    assert.equal(runsOnRebuild(step), false, `${step} belongs to a new file`)
  }
  assert.equal(runsOnRebuild('startup-timer'), true, 'work nobody has thought about still runs')
})

test('re-opening a stream that never started is that file\'s first load, so all of it runs', () => {
  // otherwise the stream comes back and sits there: autoplay was skipped as already done
  for (const step of ['resume', 'thumbnails', 'audio', 'autoplay', 'chapters', 'subtitles']) {
    assert.equal(runsOnRebuild(step, { started: false }), true, `${step} never ran for this file`)
  }
  assert.equal(runsOnRebuild('autoplay', { started: true }), false)
})

test('the seekbar keeps saying where playback is while the element underneath is empty', () => {
  const rebuild = { at: 612.5, duration: 1_440 }
  // what the element reports the moment load() empties it
  assert.deepEqual(heldPlayback(rebuild, { currentTime: 0, duration: NaN }), { position: 612.5, duration: 1_440 })
  assert.deepEqual(heldPlayback(null, { currentTime: 612.5, duration: 1_440 }), { position: 612.5, duration: 1_440 }, 'and it is the element again the moment the rebuild lands')
  assert.deepEqual(heldPlayback(null, {}), { position: 0, duration: 0 })
})

// --- a load that never becomes playback ---

test('a stalling stream is only watched while it is supposed to be moving', () => {
  assert.equal(watchesForStall({ src: null, readyState: 0 }), false, 'between files there is nothing to stall')
  assert.equal(watchesForStall({ src: 'https://cdn/a.mkv', readyState: 0, paused: true }), true, 'never started: playback only begins once the header arrives')
  assert.equal(watchesForStall({ src: 'https://cdn/a.mkv', readyState: 4, paused: true }), false, 'this one is not stalled, it is paused')
  assert.equal(watchesForStall({ src: 'https://cdn/a.mkv', readyState: 4, paused: false }), true)
  assert.equal(watchesForStall({ src: 'https://cdn/a.mkv', readyState: 0, externalPlayback: true }), false)
})

test('anything that moves while a load is going anywhere changes the fingerprint', () => {
  const base = { readyState: 1, bufferedEnd: 30, currentTime: 12, downloaded: 100 }
  const mark = loadProgressMark(base)
  assert.notEqual(loadProgressMark({ ...base, readyState: 2 }), mark)
  assert.notEqual(loadProgressMark({ ...base, bufferedEnd: 30.5 }), mark)
  assert.notEqual(loadProgressMark({ ...base, currentTime: 12.01 }), mark)
  assert.notEqual(loadProgressMark({ ...base, downloaded: 100.4 }), mark, 'a torrent still downloading is slow, not dead')
  assert.equal(loadProgressMark({ ...base }), mark)
  assert.equal(loadProgressMark({ readyState: 0, bufferedEnd: NaN, currentTime: undefined }), loadProgressMark({}), 'and nothing at all reads as nothing')
})

test('a stream that stops answering is re-opened, then reported, and never looped on', () => {
  const ticks = STALL_PATIENCE_MS / 1_000
  let state = null
  const dead = loadProgressMark({ readyState: 1, currentTime: 12 })
  /** Ticks the watchdog once a second until it wants to do something, counting the waits. */
  const until = () => {
    for (let waits = 0; waits < ticks * 10; waits++) {
      const { state: next, action } = advanceStall(state, dead, 1_000)
      state = next
      if (action !== 'wait') return { action, waits }
    }
    return { action: 'never', waits: Infinity }
  }
  const first = until()
  assert.deepEqual(first, { action: 'reload', waits: ticks }, 'a whole window of nothing changing, counted from the first look')
  assert.equal(state.reloads, 1)
  const second = until()
  assert.deepEqual(second, { action: 'reload', waits: ticks - 1 }, 'the window starts over after a re-open')
  assert.equal(state.reloads, STALL_RELOADS)
  assert.equal(until().action, 'report', 'and when re-opening it twice did nothing, the user is told')
  for (let round = 0; round < ticks * 3; round++) {
    assert.equal(advanceStall(state, dead, 1_000).action, 'wait', 'a stream nobody can fix must not become a reload loop, or a toast a second')
  }
})

test('a stalled torrent is re-opened in place; its bytes come from the client, not a link', () => {
  assert.equal(reloadPlan({ attempt: 1, debrid: false }), 'reopen')
  assert.equal(reloadPlan({ attempt: 2, debrid: false }), 'reopen')
  assert.equal(reloadPlan({ attempt: 2, debrid: false, linkAlive: false }), 'reopen', 'no probe verdict changes what a torrent can do')
})

test('a stalled debrid link is asked directly before a second 15s window is spent on it', () => {
  // the live failure: two re-opens of a link whose CDN node never sent a byte, then a
  // toast whose retry re-opened it a third time. The service pins one URL per file, so
  // a dead link can never be re-opened back to life — it has to be routed around
  assert.equal(reloadPlan({ attempt: 1, debrid: true }), 'reopen', 'one benefit of the doubt: a socket flap is fixed by a re-open')
  assert.equal(reloadPlan({ attempt: 2, debrid: true }), 'probe', 'before burning another window, ask the link itself')
  assert.equal(reloadPlan({ attempt: 2, debrid: true, linkAlive: true }), 'reopen', 'the link serves bytes, so the fault is the local pipeline')
  assert.equal(reloadPlan({ attempt: 2, debrid: true, linkAlive: false }), 'replay', 'a dead link is routed again from the top, never re-opened')
})

test('a stream that answers at all resets the watchdog', () => {
  let state = null
  const mark = loadProgressMark({ readyState: 1, bufferedEnd: 4 })
  for (let round = 0; round < (STALL_PATIENCE_MS / 1_000) - 1; round++) state = advanceStall(state, mark, 1_000).state
  const moved = advanceStall(state, loadProgressMark({ readyState: 1, bufferedEnd: 5 }), 1_000)
  assert.equal(moved.action, 'wait')
  assert.equal(moved.state.stalledMs, 0, 'a byte arrived; the patience starts over')
})

// --- what the player asks before an episode starts ---

test('an episode nobody could describe is a normal episode, not a video that never plays', () => {
  // the lookup throws when Jikan is unreachable, and that threw through the autoplay path
  assert.deepEqual(episodePrompt(undefined), { filler: null, recap: null, prompt: false })
  assert.deepEqual(episodePrompt(null), { filler: null, recap: null, prompt: false })
  assert.deepEqual(episodePrompt([]), { filler: null, recap: null, prompt: false }, 'the show is known, this episode is not')
  assert.deepEqual(episodePrompt({ filler: false, recap: false }), { filler: null, recap: null, prompt: false })
})

test('an episode worth asking about still gets asked about', () => {
  assert.deepEqual(episodePrompt({ filler: true }), { filler: 'Filler', recap: null, prompt: true })
  assert.deepEqual(episodePrompt({ recap: true }), { filler: null, recap: 'Recap', prompt: true })
})

// --- where the player picks an episode back up ---

test('a position is saved from a frame existing, not from the file being fully buffered', () => {
  // "enough buffered to play to the end" is a claim a stream fetched as it plays never
  // makes: on debrid the ten-second save ticked all episode and stored nothing
  assert.equal(savesProgress({ readyState: 2, currentTime: 612 }), true)
  assert.equal(savesProgress({ readyState: 3, currentTime: 612 }), true)
  assert.equal(savesProgress({ readyState: 4, currentTime: 612 }), true)
  assert.equal(savesProgress({ readyState: 1, currentTime: 612 }), false, 'a header is not a position')
  assert.equal(savesProgress({ readyState: 4, currentTime: 0 }), false, 'the start of a file is not progress worth storing over the last watch')
  assert.equal(savesProgress({ readyState: 0, currentTime: NaN }), false)
  assert.equal(savesProgress({ readyState: 0, currentTime: 0, error: true }), true, 'a failure resets the position deliberately')
})

test('the track list reads as a line a log can carry', () => {
  assert.equal(describeTracks([{ id: 'jpn', language: 'ja', enabled: true }, { id: 'eng', language: 'en', enabled: false }]), 'jpn(ja)* eng(en)')
  assert.equal(describeTracks([]), 'none')
  assert.equal(describeTracks(null), 'none')
})
