// What the settings screen says about how the window is being drawn. Two rules worth
// pinning: a fallback is never silent, because it costs the user real smoothness, and
// a mode that could not draw is reported as overridden rather than as their choice.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { graphicsFallbackNotice, graphicsModes } from '@/modules/graphics.js'

test('a machine drawing on the gpu is told nothing', () => {
  assert.equal(graphicsFallbackNotice({ mode: 'auto', effective: 'gpu', failedStarts: 0 }), null)
  assert.equal(graphicsFallbackNotice(), null, 'and a host that answers nothing is not an alarm')
})

test('automatic working around a driver but keeping the gpu says so, and says it is still fast', () => {
  const notice = graphicsFallbackNotice({ mode: 'auto', effective: 'nvidia-sync', failedStarts: 0 })
  assert.match(notice, /Automatic is using NVIDIA without explicit sync/)
  assert.match(notice, /Still accelerated/, 'a working around is not the same news as giving up the gpu')
})

test('automatic giving up the gpu says why, and how it comes back', () => {
  const notice = graphicsFallbackNotice({ mode: 'auto', effective: 'shm', failedStarts: 0 })
  assert.match(notice, /Automatic is using Shared memory/)
  assert.match(notice, /black window is not worth the frame rate/)
  assert.match(notice, /driver, kernel or WebKit update/, 'the user should know this is not permanent')
})

test('a launch that could not draw is reported as an override, not as a choice', () => {
  const once = graphicsFallbackNotice({ mode: 'no-gbm', effective: 'shm', failedStarts: 1 })
  assert.match(once, /A previous launch/)
  assert.match(once, /regardless of the setting/)
  assert.match(once, /clears itself/, 'and that it is not permanent')

  const again = graphicsFallbackNotice({ mode: 'auto', effective: 'safe', failedStarts: 2 })
  assert.match(again, /2 launches in a row/)
  assert.match(again, /Safe/)
})

test('a mode the user pinned and got is not a notice', () => {
  assert.equal(graphicsFallbackNotice({ mode: 'safe', effective: 'safe', failedStarts: 0 }), null)
  assert.equal(graphicsFallbackNotice({ mode: 'no-gbm', effective: 'no-gbm', failedStarts: 0 }), null)
})

test('every mode the host offers has something to show for it', () => {
  // the list the host's MODES const holds, plus the names earlier versions stored
  for (const mode of ['auto', 'gpu', 'nvidia-sync', 'no-gbm', 'shm', 'safe', 'gpu-no-gbm', 'no-dmabuf']) {
    assert.ok(graphicsModes[mode], mode)
    assert.match(graphicsModes[mode], / — /, 'a name and then what it is for')
  }
})
