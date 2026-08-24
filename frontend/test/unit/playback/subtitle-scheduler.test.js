// When the subtitle stream may restart — the rules that ended the restart livelock.
//
// The regression these guard, from main.log 2026-08-23 01:24: a 7.7GB file on a briefly
// slow link, and the old watcher restarted the stream every time the playhead's cluster
// got more than 1MB (one second of video) past the parser. Twenty-one "the stream
// restarted but delivered nothing" warnings in ninety seconds, 4 cues delivered for the
// whole episode. Playback getting ahead of the parser must never be treated as a seek.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { createSchedule, observeTime, noteRestart, shouldRestart } from '../../../common/modules/playback/subtitle-scheduler.js'

/** A schedule on a hand-cranked clock. */
function schedule (opts = {}) {
  const clock = { now: 100_000 }
  const state = createSchedule({ clock: () => clock.now, ...opts })
  return { state, clock, tick: (ms, time) => { clock.now += ms; if (time != null) observeTime(state, time) } }
}

const HD_RATE = 1_000_000 // ~8Mbps: the bitrate class the 1MB slack rule broke on

test('playback outrunning a slow parser is not a seek and does not restart the stream', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  // playback advances normally; the parser (offset) falls steadily behind the target
  for (let second = 101; second < 140; second++) {
    tick(1_000, second)
    const target = second * HD_RATE // the playhead's own cluster, marching ahead
    const offset = 100 * HD_RATE // a parser stuck where it started
    assert.equal(shouldRestart(state, { target, offset, byteRate: HD_RATE }), false,
      `at ${second}s the old code would have restarted; the gap is still within slack`)
  }
})

test('falling a long way behind earns a catch-up restart, but only once per interval', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  for (let i = 1; i <= 8; i++) tick(250, 100 + i * 0.25) // ordinary playback, no jumps
  const target = 400 * HD_RATE // the stream is minutes behind: far past any slack
  const offset = 100 * HD_RATE
  assert.equal(shouldRestart(state, { target, offset, byteRate: HD_RATE }), true, 'a real gap deserves one catch-up')
  noteRestart(state)
  tick(1_000, null)
  assert.equal(shouldRestart(state, { target: target + HD_RATE, offset, byteRate: HD_RATE }), false,
    'a second catch-up one second later is the livelock; the interval must hold it back')
  tick(15_000, null)
  assert.equal(shouldRestart(state, { target: target + 16 * HD_RATE, offset, byteRate: HD_RATE }), true,
    'once the interval passes, catching up is allowed again')
})

test('a seek restarts promptly once the playhead settles', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  tick(250, 100.25)
  tick(250, 700) // the jump
  assert.equal(shouldRestart(state, { target: 700 * HD_RATE, offset: 100 * HD_RATE, byteRate: HD_RATE }), false,
    'immediately after the jump the hand may still be on the bar')
  tick(500, 700.5) // half a second of ordinary playback at the new position
  assert.equal(shouldRestart(state, { target: 700 * HD_RATE, offset: 100 * HD_RATE, byteRate: HD_RATE }), true,
    'a settled seek restarts without waiting for any drift threshold or interval')
})

test('scrubbing coalesces into a single restart instead of a storm', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  // the user drags the bar: a new discontinuity every 100ms for two seconds
  let approved = 0
  for (let i = 0; i < 20; i++) {
    tick(100, 100 + i * 60)
    if (shouldRestart(state, { target: (100 + i * 60) * HD_RATE, offset: 100 * HD_RATE, byteRate: HD_RATE })) approved++
  }
  assert.equal(approved, 0, 'no restart while the target keeps moving')
  tick(500, 100 + 19 * 60 + 0.5) // the hand comes off, playback resumes
  assert.equal(shouldRestart(state, { target: (100 + 19 * 60) * HD_RATE, offset: 100 * HD_RATE, byteRate: HD_RATE }), true,
    'the settled position gets exactly one restart')
})

test('seeks are exempt from the catch-up rate limit', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  noteRestart(state) // the stream just restarted for any reason
  tick(1_000, 100)
  tick(250, 900) // an immediate second seek
  tick(500, 900.5)
  assert.equal(shouldRestart(state, { target: 900 * HD_RATE, offset: 100 * HD_RATE, byteRate: HD_RATE }), true,
    'a user seek is never made to wait on the drift interval')
})

test('a seek that lands in already-parsed bytes clears without a restart', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  tick(250, 50) // backward, into a scene the renderer already holds
  tick(500, 50.5)
  // target null: the caller found the position covered
  assert.equal(shouldRestart(state, { target: null, offset: 100 * HD_RATE, byteRate: HD_RATE }), false)
  // the pending seek is forgotten — the next tiny drift is not suddenly a "seek"
  tick(250, 50.75)
  assert.equal(shouldRestart(state, { target: 96 * HD_RATE, offset: 95 * HD_RATE, byteRate: HD_RATE }), false,
    'a 1-second drift after a resolved seek must not restart the stream')
})

test('with no byte rate, catch-up restarts still happen but stay rate-limited', () => {
  const { state, tick } = schedule()
  tick(0, 100)
  assert.equal(shouldRestart(state, { target: 5_000_000, offset: 0, byteRate: 0 }), true)
  noteRestart(state)
  tick(1_000, 100.25)
  assert.equal(shouldRestart(state, { target: 6_000_000, offset: 0, byteRate: 0 }), false)
})
