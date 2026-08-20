// The rule deciding whether a torrent-session notification may toast. The invariant
// the user set in stone: while debrid is the transport, torrent errors NEVER surface.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { torrentToast } from '../../../common/modules/lib/torrent-toasts.js'

test('while debrid is the transport, nothing surfaces at any level or setting', () => {
  for (const type of ['info', 'warn', 'error']) {
    for (const toasts of ['All', 'Errors', 'Warnings', 'None']) {
      assert.equal(torrentToast(type, { toasts, debridActive: true }), false,
        `${type} with '${toasts}' must stay in the log while debrid owns playback`)
    }
  }
})

test('without debrid the user preference decides, at every level', () => {
  assert.equal(torrentToast('error', { toasts: 'All', debridActive: false }), true)
  assert.equal(torrentToast('warn', { toasts: 'All', debridActive: false }), true)
  assert.equal(torrentToast('info', { toasts: 'All', debridActive: false }), true)
  assert.equal(torrentToast('error', { toasts: 'Errors', debridActive: false }), true)
  assert.equal(torrentToast('warn', { toasts: 'Errors', debridActive: false }), false)
  assert.equal(torrentToast('error', { toasts: 'Warnings', debridActive: false }), true, 'warnings-and-up includes errors')
  assert.equal(torrentToast('warn', { toasts: 'Warnings', debridActive: false }), true)
  assert.equal(torrentToast('info', { toasts: 'Warnings', debridActive: false }), false, 'info no longer bypasses the preference')
  for (const type of ['info', 'warn', 'error']) {
    assert.equal(torrentToast(type, { toasts: 'None', debridActive: false }), false)
  }
})
