// The boot-time answer to "can this platform play media at all". Written for the
// AppImage that shipped with GStreamer unable to find its plugins: every video froze
// the player, the web process died, and the only evidence was stderr. The probe plays
// a trivial silent clip right after boot so that failure becomes a line in the log.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { silentWavUri, describeMediaError, probeMediaPipeline, attachMediaProbe, PROBE_DELAY } from '../../../common/modules/lib/media-probe.js'

/** A stand-in audio element whose fate the test decides. */
function fakeAudio () {
  const listeners = {}
  return {
    addEventListener (name, handler) { (listeners[name] ??= []).push(handler) },
    removeAttribute () {},
    load () {},
    fire (name) { for (const handler of listeners[name] ?? []) handler() },
    error: null
  }
}

test('the clip is a well-formed WAV of silence', () => {
  const uri = silentWavUri()
  assert.ok(uri.startsWith('data:audio/wav;base64,'))
  const bytes = Uint8Array.from(atob(uri.slice(uri.indexOf(',') + 1)), c => c.charCodeAt(0))
  assert.equal(String.fromCharCode(...bytes.slice(0, 4)), 'RIFF')
  assert.equal(String.fromCharCode(...bytes.slice(8, 12)), 'WAVE')
  // 8-bit silence is the midpoint, not zero: zero would be a full-scale DC edge
  assert.ok(bytes.slice(44).every(sample => sample === 0x80))
})

test('a clip that plays reports ok', async () => {
  const audio = fakeAudio()
  const verdict = probeMediaPipeline({ create: () => audio, schedule: () => {} })
  audio.fire('canplaythrough')
  assert.deepEqual(await verdict, { ok: true })
})

test('a clip the platform rejects reports why', async () => {
  const audio = fakeAudio()
  const verdict = probeMediaPipeline({ create: () => audio, schedule: () => {} })
  audio.error = { code: 4 }
  audio.fire('error')
  const { ok, reason } = await verdict
  assert.equal(ok, false)
  assert.match(reason, /unsupported/)
})

test('silence is an answer too', async () => {
  // a frozen pipeline never fires anything; the timeout is what says so
  const audio = fakeAudio()
  const timers = []
  const verdict = probeMediaPipeline({ create: () => audio, timeout: 123, schedule: fn => timers.push(fn) })
  for (const fire of timers) fire()
  const { ok, reason } = await verdict
  assert.equal(ok, false)
  assert.match(reason, /no answer after 123ms/)
})

test('the first answer wins and later ones change nothing', async () => {
  const audio = fakeAudio()
  const verdict = probeMediaPipeline({ create: () => audio, schedule: () => {} })
  audio.fire('canplaythrough')
  audio.error = { code: 3 }
  audio.fire('error')
  assert.deepEqual(await verdict, { ok: true })
})

test('a platform with no audio element at all is a reported failure, not a throw', async () => {
  const { ok, reason } = await probeMediaPipeline({ create: () => { throw new Error('Audio is not defined') }, schedule: () => {} })
  assert.equal(ok, false)
  assert.match(reason, /no audio element/)
})

test('every media error code has a meaning, and unknown ones still read as words', () => {
  for (const code of [1, 2, 3, 4, 9, undefined]) {
    assert.equal(typeof describeMediaError(code === undefined ? null : { code }), 'string')
  }
  assert.match(describeMediaError({ code: 2 }), /never touches the network/)
})

test('attached, a failure reaches the console as an error pointing at the fix', async () => {
  const audio = fakeAudio()
  const logged = []
  const scheduled = []
  attachMediaProbe({
    console: { error: line => logged.push(line), debug: () => {} },
    create: () => audio,
    schedule: (fn, delay) => { scheduled.push({ fn, delay }) }
  })
  assert.equal(scheduled[0].delay, PROBE_DELAY)
  const running = scheduled[0].fn()
  audio.error = { code: 3 }
  audio.fire('error')
  await running
  assert.equal(logged.length, 1)
  assert.match(logged[0], /GStreamer/)
  assert.match(logged[0], /verify-appimage/)
})

test('attached, success stays out of the always-forwarded levels', async () => {
  const audio = fakeAudio()
  const errors = []
  const debugs = []
  const scheduled = []
  attachMediaProbe({
    console: { error: line => errors.push(line), debug: line => debugs.push(line) },
    create: () => audio,
    schedule: fn => { scheduled.push(fn) }
  })
  const running = scheduled[0]()
  audio.fire('canplaythrough')
  await running
  assert.equal(errors.length, 0)
  assert.equal(debugs.length, 1)
})
