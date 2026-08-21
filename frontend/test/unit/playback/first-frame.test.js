// The startup stopwatch that turns "it's slow to play" into a log line with a
// culprit: how long to the container header, how long to a first frame.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { createStartupTimer, SLOW_START } from '../../../common/modules/playback/first-frame.js'

function harness (start = 0) {
  let clock = start
  const debugs = []
  const warns = []
  const timer = createStartupTimer({
    now: () => clock,
    console: { debug: line => debugs.push(line), warn: line => warns.push(line) }
  })
  return { timer, debugs, warns, tick: ms => { clock += ms } }
}

test('a normal start reports both seams at debug level', () => {
  const { timer, debugs, warns, tick } = harness()
  timer.start('episode 3.mkv')
  tick(400)
  timer.metadata()
  tick(300)
  const line = timer.playing()
  assert.match(line, /episode 3\.mkv started in 700ms/)
  assert.match(line, /metadata in 400ms/)
  assert.deepEqual(debugs, [line])
  assert.deepEqual(warns, [])
})

test('a slow start is a warning, which always reaches the log', () => {
  const { timer, warns, tick } = harness()
  timer.start('episode 9.mkv')
  tick(SLOW_START + 500)
  timer.playing()
  assert.equal(warns.length, 1)
  assert.match(warns[0], /slow start/)
})

test('playing reports once; a second frame event says nothing new', () => {
  const { timer, debugs, tick } = harness()
  timer.start('a.mkv')
  tick(100)
  timer.playing()
  tick(100)
  assert.equal(timer.playing(), null)
  assert.equal(debugs.length, 1)
})

test('metadata keeps its first answer; later reports do not move it', () => {
  const { timer, tick } = harness()
  timer.start('a.mkv')
  tick(200)
  timer.metadata()
  tick(500)
  timer.metadata()
  assert.match(timer.playing(), /metadata in 200ms/)
})

test('a cancelled start blames nobody', () => {
  const { timer, debugs, warns, tick } = harness()
  timer.start('abandoned.mkv')
  tick(50)
  timer.cancel()
  assert.equal(timer.playing(), null)
  assert.deepEqual([...debugs, ...warns], [])
})

test('a restart forgets the start it interrupted', () => {
  const { timer, tick } = harness()
  timer.start('first.mkv')
  tick(5_000)
  timer.start('second.mkv')
  tick(250)
  const line = timer.playing()
  assert.match(line, /second\.mkv started in 250ms/)
})

test('a start that never saw metadata says so', () => {
  const { timer, tick } = harness()
  timer.start('a.mkv')
  tick(100)
  assert.match(timer.playing(), /metadata never reported/)
})
