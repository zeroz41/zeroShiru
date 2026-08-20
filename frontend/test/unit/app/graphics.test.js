// What the settings screen says about how the window is being drawn. The rule worth
// pinning is that a silent fallback is not acceptable: dropping the GPU path costs the
// user real smoothness, so if it happens they get told why and how to undo it.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { graphicsFallbackNotice, graphicsModes } from '@/modules/graphics.js'

test('a machine drawing normally is told nothing', () => {
  assert.equal(graphicsFallbackNotice({ mode: 'auto', effective: 'auto', failedStarts: 0 }), null)
  assert.equal(graphicsFallbackNotice(), null, 'and a host that answers nothing is not an alarm')
})

test('automatic falling back says so, and says what it cost', () => {
  const once = graphicsFallbackNotice({ mode: 'auto', effective: 'no-dmabuf', failedStarts: 1 })
  assert.match(once, /A previous launch/)
  assert.match(once, /No DMABUF/)
  assert.match(once, /smoothness/, 'the user should know this is why the app feels slower')

  const again = graphicsFallbackNotice({ mode: 'auto', effective: 'safe', failedStarts: 2 })
  assert.match(again, /2 launches in a row/)
  assert.match(again, /Safe/)
})

test('a mode the user pinned is their decision, not a fallback', () => {
  assert.equal(graphicsFallbackNotice({ mode: 'safe', effective: 'safe', failedStarts: 3 }), null)
})

test('every mode the host offers has something to show for it', () => {
  for (const mode of ['auto', 'no-dmabuf', 'safe']) {
    assert.ok(graphicsModes[mode], mode)
    assert.match(graphicsModes[mode], / — /, 'a name and then what it is for')
  }
})
