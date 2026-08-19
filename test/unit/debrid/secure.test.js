// Debrid links are account bound and time limited. Streaming one over cleartext
// would expose both the link and the viewing traffic, so the HTTPS half of the
// DebridFile contract is enforced rather than assumed of each service.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { secureFiles, DebridError } from '../../../common/modules/debrid/service.js'

const file = url => ({ name: 'Show - 01.mkv', path: '/Show - 01.mkv', size: 1, url })

test('https links pass through untouched', () => {
  const files = [file('https://cdn.example.test/a.mkv'), file('HTTPS://cdn.example.test/b.mkv')]
  assert.deepEqual(secureFiles(files, 'Test'), files)
})

test('cleartext links are dropped rather than played', () => {
  const secure = file('https://cdn.example.test/a.mkv')
  const result = secureFiles([secure, file('http://cdn.example.test/b.mkv')], 'Test')
  assert.deepEqual(result, [secure])
})

test('a service offering nothing secure fails loudly, naming itself', () => {
  for (const bad of [[file('http://cdn.example.test/a.mkv')], [file('')], [file(undefined)], [{}], [], null]) {
    assert.throws(() => secureFiles(bad, 'Test Service'), error => {
      assert.ok(error instanceof DebridError)
      assert.match(error.message, /Test Service/)
      assert.doesNotMatch(error.message, /undefined/)
      return true
    })
  }
})

test('protocol relative and lookalike schemes do not pass as https', () => {
  for (const url of ['//cdn.example.test/a.mkv', 'httpsx://cdn.example.test/a.mkv', 'ftp://cdn.example.test/a.mkv', 'javascript:alert(1)', 'https:/cdn.example.test/a.mkv']) {
    assert.throws(() => secureFiles([file(url)], 'Test'), DebridError, `${url} must not be treated as secure`)
  }
})
