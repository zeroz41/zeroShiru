// Failure-reporting tests: every failure mode must produce a message a user can
// act on. Regression guard for "Request failed with status undefined", which is
// what the offline short-circuit used to surface as.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import RealDebrid from '../../../common/modules/debrid/realdebrid.js'
import { DebridError, DebridAuthError, DebridNetworkError } from '../../../common/modules/debrid/service.js'

let service
beforeEach(() => {
  service = new RealDebrid('test-key')
})

/** Shiru's networking layer returns this plain object instead of a Response while offline. */
const OFFLINE_RESULT = { message: 'failed to fetch: client is offline' }

test('the offline short-circuit reports being offline, never "status undefined"', async () => {
  globalThis.fetch = async () => OFFLINE_RESULT
  await assert.rejects(service.validate(), error => {
    assert.ok(error instanceof DebridNetworkError, `expected DebridNetworkError, got ${error.name}`)
    assert.match(error.message, /offline/i)
    assert.doesNotMatch(error.message, /undefined/, 'messages must never contain "undefined"')
    return true
  })
})

test('offline failures are not retried, so the error surfaces immediately', async () => {
  let calls = 0
  globalThis.fetch = async () => { calls++; return OFFLINE_RESULT }
  await assert.rejects(service.validate(), DebridNetworkError)
  assert.equal(calls, 1, 'retrying while offline only delays the error')
})

test('a thrown fetch (DNS, TLS, aborted) surfaces its own message', async () => {
  globalThis.fetch = async () => { throw new TypeError('Failed to fetch') }
  await assert.rejects(service.validate(), error => {
    assert.match(error.message, /failed to fetch/i)
    return true
  })
})

test('no failure mode produces a message containing "undefined"', async () => {
  const responses = [
    { ok: false, status: 401, headers: { get: () => null }, json: async () => ({ error: 'bad_token', error_code: 8 }) },
    { ok: false, status: 403, headers: { get: () => null }, json: async () => ({ error: 'account_locked' }) },
    { ok: false, status: 503, headers: { get: () => null }, json: async () => { throw new Error('not json') } },
    { ok: false, status: 500, headers: { get: () => null }, json: async () => null },
    OFFLINE_RESULT,
    {},
    null
  ]
  for (const response of responses) {
    const client = new RealDebrid('test-key')
    globalThis.fetch = async () => response
    await assert.rejects(client.validate(), error => {
      assert.ok(error instanceof DebridError, `expected a DebridError for ${JSON.stringify(response)?.slice(0, 40)}`)
      assert.doesNotMatch(error.message, /undefined/, `message for ${JSON.stringify(response)?.slice(0, 40)} must not say undefined`)
      assert.ok(error.message.length > 5, 'messages must be descriptive')
      return true
    })
    client.destroy()
  }
})

test('a free account is rejected with an actionable message', async () => {
  globalThis.fetch = async () => ({ ok: true, status: 200, headers: { get: () => null }, json: async () => ({ username: 'tester', type: 'free' }) })
  await assert.rejects(service.validate(), error => {
    assert.ok(error instanceof DebridAuthError)
    assert.match(error.message, /premium/i)
    return true
  })
})

// Real-Debrid answers 403 for blocked/unavailable files as well as for bad keys.
// Treating those as auth errors is not cosmetic: mapFiles rethrows auth errors, so a
// single DMCA-blocked file in a pack would abort the whole resolve instead of being skipped.
test('a blocked file is a plain error naming the cause, not an auth error', async () => {
  globalThis.fetch = async () => ({ ok: false, status: 403, headers: { get: () => null }, json: async () => ({ error: 'infringing_file', error_code: 35 }) })
  await assert.rejects(service.validate(), error => {
    assert.ok(error instanceof DebridError, 'must still be a DebridError')
    assert.ok(!(error instanceof DebridAuthError), 'must NOT be an auth error, that aborts a whole pack resolve')
    assert.match(error.message, /will not serve|different release/i, 'the message must say the release is the problem, not the moment')
    assert.doesNotMatch(error.message, /infringing_file|undefined/, 'raw API codes must not reach the user')
    return true
  })
})

test('key and permission failures are still auth errors, with readable messages', async () => {
  for (const [code, pattern] of [[8, /API key/i], [9, /denied|permission/i]]) {
    globalThis.fetch = async () => ({ ok: false, status: 403, headers: { get: () => null }, json: async () => ({ error: 'x', error_code: code }) })
    await assert.rejects(new RealDebrid('test-key').validate(), error => {
      assert.ok(error instanceof DebridAuthError, `error_code ${code} must stay an auth error`)
      assert.match(error.message, pattern)
      return true
    })
  }
  // a 403 with no code at all is still treated as an auth problem, the safe default
  globalThis.fetch = async () => ({ ok: false, status: 403, headers: { get: () => null }, json: async () => ({ error: 'account_locked' }) })
  await assert.rejects(new RealDebrid('test-key').validate(), error => error instanceof DebridAuthError)
})

test('account limits report what the user has to do about them', async () => {
  for (const [code, pattern] of [[21, /active.*downloads/i], [23, /traffic/i], [34, /rate limit/i], [36, /fair usage/i]]) {
    globalThis.fetch = async () => ({ ok: false, status: 503, headers: { get: () => null }, json: async () => ({ error: 'x', error_code: code }) })
    await assert.rejects(new RealDebrid('test-key').validate(), error => {
      assert.match(error.message, pattern, `error_code ${code}`)
      assert.ok(!(error instanceof DebridAuthError), `error_code ${code} is not an auth failure`)
      return true
    })
  }
})
