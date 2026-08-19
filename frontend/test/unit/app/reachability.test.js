// How a connectivity probe is read. The bug these were written for: the ping goes out
// `no-cors` because connectivity endpoints carry no CORS headers, so it comes back
// opaque — status 0, ok false — and the old code required `res.ok`. Under Electron web
// security was relaxed and the response was readable; under Tauri's tauri:// origin it
// is not, so a perfectly working connection read as an outage and the app opened on an
// offline banner with nothing loaded.
//
// The second rule here matters just as much on bad internet: no answer is not an answer.
// A link too slow to finish a probe inside the budget must keep whatever was believed
// rather than being reported as an outage.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { isConnected, readResponse, readError } from '../../../common/modules/reachability.js'

test('an opaque answer is a working connection', () => {
  // the only shape a no-cors ping can ever produce
  assert.equal(readResponse({ type: 'opaque', status: 0, ok: false }), 'online')
})

test('the promised 204 is a working connection', () => {
  assert.equal(readResponse({ type: 'cors', status: 204, ok: true }), 'online')
  assert.equal(readResponse({ type: 'basic', status: 200, ok: true }), 'online')
})

test('a success that is not the promised one is something answering for it', () => {
  // a hotel splash page, a filtering proxy: reachable, but not the internet
  assert.equal(readResponse({ type: 'cors', status: 302, ok: false }), 'portal')
  assert.equal(readResponse({ type: 'cors', status: 307, ok: false }), 'portal')
})

test('an endpoint having a bad day says nothing about the connection', () => {
  for (const status of [500, 502, 503, 429, 403]) {
    assert.equal(readResponse({ type: 'cors', status, ok: false }), 'unknown', `${status} is news about them`)
  }
})

test('nothing to read is not a verdict', () => {
  assert.equal(readResponse(undefined), 'unknown')
  assert.equal(readResponse(null), 'unknown')
})

test('our own timeout is not evidence of an outage', () => {
  // pingWith aborts the request itself once the budget runs out
  assert.equal(readError({ name: 'AbortError' }), 'unknown')
  assert.equal(readError({ name: 'TimeoutError' }), 'unknown')
})

test('a request that could not be made at all is an outage', () => {
  assert.equal(readError(new TypeError('Load failed')), 'offline')
  assert.equal(readError({ name: 'NetworkError', message: 'failed to fetch' }), 'offline')
  assert.equal(readError(undefined), 'offline')
})

test('only a definite answer changes what is believed', () => {
  assert.equal(isConnected('online', false), true)
  assert.equal(isConnected('online', true), true, 'a connection that came back is online again')
  assert.equal(isConnected('offline', false), false)
  assert.equal(isConnected('portal', false), false, 'a portal is not the internet')
})

test('an unanswered probe leaves the state exactly as it was', () => {
  assert.equal(isConnected('unknown', false), true, 'a slow link must not raise an offline banner')
  assert.equal(isConnected('unknown', true), false, 'nor clear one that is already up')
})

test('with nothing believed yet, only an answer counts as connected', () => {
  // startup: wasOffline is false, so unknown stays online and the app opens normally
  assert.equal(isConnected('unknown'), true)
  assert.equal(isConnected('offline'), false)
})
