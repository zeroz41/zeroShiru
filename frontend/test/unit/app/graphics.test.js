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

test('automatic taking the safe rung says why, and what the narrower option is', () => {
  const notice = graphicsFallbackNotice({ mode: 'auto', effective: 'no-dmabuf', failedStarts: 0 })
  assert.match(notice, /Automatic is using No DMABUF/)
  assert.match(notice, /black window is not worth the frame rate/)
  assert.match(notice, /GPU without GBM/, 'the user should know there is something to try')
})

test('a launch that could not draw is reported as an override, not as a choice', () => {
  const once = graphicsFallbackNotice({ mode: 'gpu-no-gbm', effective: 'no-dmabuf', failedStarts: 1 })
  assert.match(once, /A previous launch/)
  assert.match(once, /regardless of the setting/)
  assert.match(once, /clears itself/, 'and that it is not permanent')

  const again = graphicsFallbackNotice({ mode: 'auto', effective: 'safe', failedStarts: 2 })
  assert.match(again, /2 launches in a row/)
  assert.match(again, /Safe/)
})

test('a mode the user pinned and got is not a notice', () => {
  assert.equal(graphicsFallbackNotice({ mode: 'safe', effective: 'safe', failedStarts: 0 }), null)
  assert.equal(graphicsFallbackNotice({ mode: 'gpu-no-gbm', effective: 'gpu-no-gbm', failedStarts: 0 }), null)
})

test('every mode the host offers has something to show for it', () => {
  for (const mode of ['auto', 'gpu-no-gbm', 'no-dmabuf', 'safe']) {
    assert.ok(graphicsModes[mode], mode)
    assert.match(graphicsModes[mode], / — /, 'a name and then what it is for')
  }
})
