// The page's own diagnostics reaching the host log. What these pin is the reason the
// module exists: a failure must never be silent, and a working app must never drown
// the log in chatter nobody asked for.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import {
  forwards, describe, format, describeFailure, describeDebug, redact, createForwarder,
  attachDiagnostics, debugLogging, MAX_MESSAGE, MAX_BATCH
} from '@/modules/lib/diagnostics.js'

/** A console that records instead of printing, and the calls made through it. */
function fakeConsole () {
  const printed = []
  const method = (name) => (...args) => printed.push([name, args])
  return { printed, error: method('error'), warn: method('warn'), info: method('info'), log: method('log'), debug: method('debug') }
}

/** An event target that only fires when a test says so. */
function fakeEvents () {
  const listeners = new Map()
  return {
    listeners,
    addEventListener: (type, callback) => listeners.set(type, callback),
    removeEventListener: (type) => listeners.delete(type),
    fire: (type, event) => listeners.get(type)?.(event)
  }
}

/** Collects the batches a forwarder hands over, and the timers it asked for. */
function fakeHost () {
  const batches = []
  const timers = []
  return {
    batches,
    timers,
    send: (entries) => batches.push(entries),
    schedule: (callback) => { timers.push(callback); return { unref () {} } },
    run: () => { const pending = timers.splice(0); for (const callback of pending) callback() }
  }
}

test('a failure is always worth logging, chatter only when someone is reading', () => {
  assert.equal(forwards('error', false), true)
  assert.equal(forwards('warn', false), true, 'a warning is how the app reports a degraded path')
  assert.equal(forwards('info', false), false)
  assert.equal(forwards('debug', false), false, 'a busy app debug-logs thousands of lines a minute')
  assert.equal(forwards('debug', true), true, 'and all of them are wanted once debug logging is on')
})

test('a console argument is described rather than printed as [object Object]', () => {
  assert.equal(describe('plain'), 'plain')
  assert.equal(describe(42), '42')
  assert.equal(describe(undefined), 'undefined')
  assert.match(describe(new TypeError('vibrate is not a function')), /TypeError: vibrate is not a function/)
  assert.equal(describe({ kind: 'timeout' }), '{"kind":"timeout"}')

  const cyclic = { name: 'results' }
  cyclic.self = cyclic
  assert.match(describe(cyclic), /circular/, 'a cyclic object still gets a line')

  const hostile = { get boom () { throw new Error('nope') } }
  assert.doesNotThrow(() => describe(hostile), 'a getter that throws must not take the log entry down')
})

test('an enormous line is cut here as well as in the host', () => {
  const line = format(['x'.repeat(MAX_MESSAGE + 500)])
  assert.ok(line.length < MAX_MESSAGE + 200)
  assert.match(line, /more characters/)
})

test('an uncaught error says where it happened', () => {
  const described = describeFailure(new Error('boom'), { filename: 'index.js', lineno: 4, colno: 9 })
  assert.match(described, /boom/)
  assert.match(described, /index\.js:4:9/)
  // a rejection has no position and must not invent one
  assert.equal(describeFailure({ kind: 'network', message: 'offline' }), '{"kind":"network","message":"offline"}')
})

test('lines are batched, so one call carries a burst', () => {
  const host = fakeHost()
  const forwarder = createForwarder({ send: host.send, schedule: host.schedule })

  forwarder.record('error', 'console.error', 'first')
  forwarder.record('warn', 'console.warn', 'second')
  assert.equal(host.batches.length, 0, 'nothing crosses until the batch is due')
  assert.equal(forwarder.pending, 2)

  host.run()
  assert.equal(host.batches.length, 1, 'and then one call carries both')
  assert.deepEqual(host.batches[0].map(entry => entry.message), ['first', 'second'])
  assert.equal(host.timers.length, 0, 'a flushed forwarder is not still holding a timer')
})

test('a burst goes at once rather than growing without bound', () => {
  const host = fakeHost()
  const forwarder = createForwarder({ send: host.send, schedule: host.schedule })
  for (let index = 0; index < MAX_BATCH; index++) forwarder.record('error', 'loop', `line ${index}`)
  assert.equal(host.batches.length, 1, 'the cap flushes without waiting for the timer')
  assert.equal(forwarder.pending, 0)
})

test('a host that cannot log never takes the page down with it', () => {
  const host = fakeHost()
  const forwarder = createForwarder({
    send: () => { throw new Error('the host is gone') },
    schedule: host.schedule
  })
  forwarder.record('error', 'console.error', 'still worth trying')
  assert.doesNotThrow(() => host.run())

  const rejecting = createForwarder({ send: () => Promise.reject(new Error('ipc closed')), schedule: host.schedule })
  rejecting.record('error', 'console.error', 'and an async failure is caught too')
  assert.doesNotThrow(() => host.run())
})

test('attaching forwards the console without swallowing it', () => {
  const host = fakeHost()
  const console = fakeConsole()
  const events = fakeEvents()
  const detach = attachDiagnostics({ send: host.send, console, target: events, schedule: host.schedule })

  console.error('debrid check failed', { kind: 'timeout' })
  console.debug('ui:debrid asking about 40 releases')
  host.run()

  assert.deepEqual(console.printed[0], ['error', ['debrid check failed', { kind: 'timeout' }]], 'the devtools console still gets everything')
  assert.equal(host.batches.length, 1)
  assert.equal(host.batches[0].length, 1, 'and only the failure crossed, with debug logging off')
  assert.equal(host.batches[0][0].scope, 'console.error')
  assert.match(host.batches[0][0].message, /timeout/)

  detach()
  console.error('after detaching')
  host.run()
  assert.equal(host.batches.length, 1, 'detaching puts the console back')
})

test('an uncaught error and an unhandled rejection both reach the log', () => {
  const host = fakeHost()
  const events = fakeEvents()
  attachDiagnostics({ send: host.send, console: fakeConsole(), target: events, schedule: host.schedule })

  events.fire('error', { error: new TypeError('navigator.vibrate is not a function'), filename: 'click.js', lineno: 12, colno: 3 })
  events.fire('unhandledrejection', { reason: new Error('resolve never answered') })
  host.run()

  const messages = host.batches.flat().map(entry => entry.message)
  assert.equal(messages.length, 2)
  assert.match(messages[0], /navigator\.vibrate/)
  assert.match(messages[0], /click\.js:12:3/)
  assert.match(messages[1], /resolve never answered/)
})

test('a host with no log leaves the console alone', () => {
  const console = fakeConsole()
  const original = console.error
  const detach = attachDiagnostics({ send: null, console, target: fakeEvents() })
  assert.equal(console.error, original, 'hooking a console costs something, and buys nothing here')
  assert.doesNotThrow(() => detach())
})

test('debug logging follows the same switch the debug package reads', () => {
  assert.equal(debugLogging({ getItem: () => 'ui:*' }), true)
  assert.equal(debugLogging({ getItem: () => null }), false)
  assert.equal(debugLogging(undefined), false, 'a host without storage is not verbose')
  assert.equal(debugLogging({ getItem () { throw new Error('blocked') } }), false, 'and storage that refuses is not a crash')
})

test('a debug namespace line is readable as text, not as console styling', () => {
  // what the debug package hands its logger in a browser
  const args = ['%cui:debrid %casking about 40 releases %c+12ms', 'color:#0000CC', 'color:inherit', 'color:#0000CC']
  assert.equal(describeDebug(args), 'ui:debrid asking about 40 releases +12ms')
  assert.equal(describeDebug(['plain line']), 'plain line', 'and a logger without colours is left alone')
})

test('debug namespaces reach the log, which hooking the console cannot do alone', () => {
  const host = fakeHost()
  // the package captures console.debug at its own import and calls that forever, so a
  // console hook installed later sees nothing it writes
  const written = []
  const debugPackage = { log: (...args) => written.push(args) }
  const console = fakeConsole()
  const detach = attachDiagnostics({
    send: host.send,
    verbose: () => true,
    console,
    target: fakeEvents(),
    debug: debugPackage,
    schedule: host.schedule
  })

  debugPackage.log('%cui:debrid %cavailability check failed %c+3ms', 'color:#0000CC', 'color:inherit', 'color:#0000CC')
  host.run()
  assert.equal(written.length, 1, 'the devtools console still gets it')
  assert.equal(host.batches[0][0].message, 'ui:debrid availability check failed +3ms')
  assert.equal(host.batches[0][0].level, 'debug')

  detach()
  debugPackage.log('after detaching')
  host.run()
  assert.equal(host.batches.length, 1)
})

test('debug output stays out of the log while debug logging is off', () => {
  const host = fakeHost()
  const debugPackage = { log: () => {} }
  attachDiagnostics({ send: host.send, console: fakeConsole(), target: fakeEvents(), debug: debugPackage, schedule: host.schedule })
  debugPackage.log('%cui:anime %cparsed 300 titles %c+1ms', 'color:#0000CC', 'color:inherit', 'color:#0000CC')
  host.run()
  assert.equal(host.batches.length, 0, 'a busy app would write thousands of these a minute')
})

test('a key never reaches a log the user is invited to send to someone', () => {
  // the settings object alone carries every debrid key the user has, and the app prints
  // it at startup when debug logging is on
  const settings = { debridService: 'torbox', debridApiKeys: { torbox: '83bf324a-d894-436e-bdcf-c1fc15e37e42' }, debridMode: 'prefer' }
  const line = format(['settings', settings])
  assert.ok(!line.includes('83bf324a'), line)
  assert.match(line, /redacted/)
  assert.match(line, /torbox/, 'everything that is not a secret still reads normally')

  assert.match(redact('GET https://api.torbox.app/v1/api/user/me?token=abc123def'), /token=\[redacted\]/)
  assert.match(redact('authorization: Bearer eyJhbGciOi.J9.sig'), /Bearer \[redacted\]/)
  assert.equal(redact('nothing to hide here'), 'nothing to hide here')
})

test('terminal colouring never reaches the log', () => {
  const coloured = '\u001b[38;5;46;1mui:settings \u001b[0mv6.8.0 \u001b[38;5;46;1m+0ms\u001b[0m'
  const line = format([coloured])
  assert.ok(!line.includes('\u001b'), JSON.stringify(line))
  assert.match(line, /ui:settings/)
})

test('an aborted request is teardown noise, not an error the log should drown in', () => {
  // the subtitle streamer ends its open-ended range reads by aborting them — that is
  // the mechanism working, and it was reaching main.log as an error per teardown
  const host = fakeHost()
  const events = fakeEvents()
  attachDiagnostics({ send: host.send, console: fakeConsole(), target: events, schedule: host.schedule })

  const abort = new Error('The operation was aborted.')
  abort.name = 'AbortError'
  events.fire('unhandledrejection', { reason: abort })
  events.fire('unhandledrejection', { reason: new Error('a real failure') })
  host.run()

  const entries = host.batches.flat()
  assert.equal(entries.length, 1, 'with debug logging off, only the real failure crosses')
  assert.match(entries[0].message, /real failure/)

  // with debug logging on the abort still appears, at debug level, for whoever is tracing
  const verboseHost = fakeHost()
  const verboseEvents = fakeEvents()
  attachDiagnostics({ send: verboseHost.send, verbose: () => true, console: fakeConsole(), target: verboseEvents, schedule: verboseHost.schedule })
  verboseEvents.fire('unhandledrejection', { reason: abort })
  verboseHost.run()
  const verboseEntries = verboseHost.batches.flat()
  assert.equal(verboseEntries.length, 1)
  assert.equal(verboseEntries[0].level, 'debug')
})
