import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { safeTorBoxPath } from '../../tools/live-link.js'

test('TorBox live-test failures never print the API key embedded in requestdl URLs', () => {
  const path = '/torrents/requestdl?torrent_id=1&file_id=2&redirect=false&token=super-secret&extra=ok'
  const safe = safeTorBoxPath(path)
  assert.doesNotMatch(safe, /super-secret/)
  assert.match(safe, /token=\[redacted\]/)
  assert.match(safe, /extra=ok/)
})
