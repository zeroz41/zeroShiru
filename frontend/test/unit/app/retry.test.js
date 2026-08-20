// When to stop asking a source that keeps saying no. The bug: three request limiters
// answered a rate limit by waiting and trying again with no count of how many times
// they had — so a source that stayed limited was asked forever, and the episode list
// or the play waiting on that answer waited forever with it.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { retryWorthwhile, RATE_LIMIT_RETRIES, ERROR_RETRIES } from '../../../common/modules/lib/retry.js'

test('being asked to slow down buys several more attempts, not unlimited ones', () => {
  for (let retryCount = 0; retryCount < RATE_LIMIT_RETRIES; retryCount++) {
    assert.equal(retryWorthwhile({ retryCount, limited: true }), true, `attempt ${retryCount} is still worth making`)
  }
  assert.equal(retryWorthwhile({ retryCount: RATE_LIMIT_RETRIES, limited: true }), false, 'a limit that never lifts must let go of the caller')
  assert.equal(retryWorthwhile({ retryCount: 99, limited: true }), false)
})

test('a plain failure is retried once, the way the search path already did', () => {
  assert.equal(retryWorthwhile({ retryCount: 0 }), true)
  assert.equal(retryWorthwhile({ retryCount: ERROR_RETRIES }), false)
})

test('the budget is generous enough not to punish a slow link', () => {
  // waits come from the service's own retry-after, so the count is what bounds it
  assert.ok(RATE_LIMIT_RETRIES >= 3, 'a busy API is not a failure')
  assert.ok(RATE_LIMIT_RETRIES <= 5, 'but nothing may wait on it indefinitely')
})

test('a missing attempt count reads as the first attempt', () => {
  assert.equal(retryWorthwhile({}), true)
  assert.equal(retryWorthwhile(), true)
  assert.equal(retryWorthwhile({ retryCount: undefined, limited: true }), true)
})
