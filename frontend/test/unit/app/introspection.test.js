// The diagnostics panel's judgments. A wrong "healthy" badge on a wedged service
// would defeat the point of the surface, so the verdict order is pinned here.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { prettyDuration, serviceVerdict, lineAllowanceNotice, LOG_PRESETS } from '@/modules/lib/introspection.js'

test('durations read like a person would say them', () => {
  assert.equal(prettyDuration(0), '0s')
  assert.equal(prettyDuration(41_000), '41s')
  assert.equal(prettyDuration(90_000), '1m 30s')
  assert.equal(prettyDuration(3 * 3_600_000 + 5 * 60_000), '3h 5m')
  assert.equal(prettyDuration(undefined), '—')
  assert.equal(prettyDuration(-5), '—')
})

test('the worst condition wins the badge', () => {
  assert.deepEqual(serviceVerdict({ quiet: true, paused_for_ms: 9_000, sweeping: true }), { label: 'not answering', tone: 'danger' })
  assert.equal(serviceVerdict({ paused_for_ms: 12_000 }).label, 'rate limited 12s')
  assert.equal(serviceVerdict({ orphaned_removals: 2 }).label, 'owes 2 cleanups')
  assert.equal(serviceVerdict({ orphaned_removals: 1 }).label, 'owes 1 cleanup')
  assert.deepEqual(serviceVerdict({ sweeping: true }), { label: 'sweeping', tone: 'ok' })
  assert.deepEqual(serviceVerdict({}), { label: 'healthy', tone: 'ok' })
  assert.deepEqual(serviceVerdict(undefined), { label: 'healthy', tone: 'ok' })
})

test('the line allowance only speaks when it matters', () => {
  assert.equal(lineAllowanceNotice({ renderer_lines: 100, renderer_line_cap: 20_000 }), null)
  assert.match(lineAllowanceNotice({ renderer_lines: 18_000, renderer_line_cap: 20_000 }), /90%/)
  assert.match(lineAllowanceNotice({ renderer_lines: 20_000, renderer_line_cap: 20_000 }), /reset the log/)
  assert.equal(lineAllowanceNotice(undefined), null)
})

test('every preset names a filter the host can parse, and default means default', () => {
  assert.equal(LOG_PRESETS[0].filter, '')
  for (const preset of LOG_PRESETS) {
    assert.equal(typeof preset.label, 'string')
    assert.ok(!/\s/.test(preset.filter), `directives have no spaces: ${preset.filter}`)
  }
})
