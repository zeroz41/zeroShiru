// Asset URLs that survive being resolved somewhere other than the page.
// The bug: the subtitle renderer fetches its fonts inside a worker that lives under
// assets/, so './Roboto.ttf' asked for 'assets/Roboto.ttf' and 404'd — the fallback
// font never loaded, and subtitles whose font is not embedded had nothing to draw with.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import { assetUrl } from '../../../common/modules/lib/asset.js'

const PAGE = 'tauri://localhost/app.html'

test('an app-root path resolves against the page, not against whoever asks', () => {
  assert.equal(assetUrl('/Roboto.ttf', PAGE), 'tauri://localhost/Roboto.ttf')
  assert.equal(assetUrl('/NotoSansCJK.otf', PAGE), 'tauri://localhost/NotoSansCJK.otf')
  // the shape that broke: resolved inside assets/, a relative path points at a sibling
  assert.equal(assetUrl('./Roboto.ttf', 'tauri://localhost/assets/jassub-worker.js'), 'tauri://localhost/assets/Roboto.ttf')
  assert.equal(assetUrl('/Roboto.ttf', 'tauri://localhost/assets/jassub-worker.js'), 'tauri://localhost/Roboto.ttf',
    'an app-root path means the same thing wherever it is read')
})

test('a host serving the app from a subdirectory still gets its own assets', () => {
  // the TV hosts do exactly this
  assert.equal(assetUrl('Roboto.ttf', 'file:///usr/share/app/index.html'), 'file:///usr/share/app/Roboto.ttf')
})

test('an absolute URL is left alone, and nonsense is handed back unchanged', () => {
  assert.equal(assetUrl('https://cdn.example/font.ttf', PAGE), 'https://cdn.example/font.ttf')
  assert.equal(assetUrl('', PAGE), '')
  assert.equal(assetUrl(null, PAGE), null)
  assert.equal(assetUrl('/Roboto.ttf', 'not a base'), '/Roboto.ttf')
})
