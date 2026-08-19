// windowFiles caps how many stream links one resolve requests, sliced AROUND the episode being
// played. The failure it guards against is quiet and nasty: cap a 200-episode pack to its first
// 60 files and asking for episode 150 resolves successfully — then plays the wrong episode.
import { test } from 'bun:test'
import assert from 'node:assert/strict'
import DebridService from '../../../common/modules/debrid/service.js'

const pack = length => Array.from({ length }, (_, index) => ({ path: `/Episode ${String(index + 1).padStart(3, '0')}.mkv`, size: 1000 }))
const paths = files => files.map(file => file.path)
const episode = (files, number) => files.find(file => file.path === `/Episode ${String(number).padStart(3, '0')}.mkv`)

test('a pack within the cap is passed through untouched', () => {
  const files = pack(60)
  assert.equal(DebridService.windowFiles(files, episode(files, 30), 60), files)
})

test('the requested episode always survives the cap, wherever it sits', () => {
  const files = pack(200)
  for (const wanted of [1, 2, 30, 100, 170, 199, 200]) {
    const windowed = DebridService.windowFiles(files, episode(files, wanted), 60)
    assert.equal(windowed.length, 60, `episode ${wanted}: the cap holds`)
    assert.ok(windowed.includes(episode(files, wanted)), `episode ${wanted} must survive its own window`)
  }
})

test('the window centers on the episode, so next and previous both stay reachable', () => {
  const files = pack(200)
  const windowed = DebridService.windowFiles(files, episode(files, 100), 60)
  assert.ok(windowed.includes(episode(files, 99)), 'previous episode')
  assert.ok(windowed.includes(episode(files, 101)), 'next episode')
  const index = windowed.indexOf(episode(files, 100))
  assert.ok(index >= 25 && index <= 35, `episode should sit near the middle, sat at ${index}`)
})

test('a window near the start clamps without shrinking', () => {
  const files = pack(200)
  const windowed = DebridService.windowFiles(files, episode(files, 3), 60)
  assert.equal(windowed[0], files[0], 'clamped to the start')
  assert.equal(windowed.length, 60, 'and still full size')
})

test('a window near the end clamps without running past the pack', () => {
  const files = pack(200)
  const windowed = DebridService.windowFiles(files, episode(files, 198), 60)
  assert.equal(windowed[59], files[199], 'clamped to the end')
  assert.equal(windowed.length, 60)
})

test('torrent order is preserved, which in-player navigation depends on', () => {
  const files = pack(200)
  const windowed = DebridService.windowFiles(files, episode(files, 100), 60)
  assert.deepEqual(paths(windowed), [...paths(windowed)].sort(), 'files must stay in torrent order')
})

test('no target takes the head of the list rather than guessing', () => {
  const files = pack(200)
  assert.deepEqual(DebridService.windowFiles(files, null, 60), files.slice(0, 60))
})

test('a target missing from the list degrades to the head, never to an empty window', () => {
  const files = pack(200)
  const windowed = DebridService.windowFiles(files, { path: '/not-in-the-pack.mkv', size: 1 }, 60)
  assert.deepEqual(windowed, files.slice(0, 60))
})

test('an odd cap still keeps the target inside', () => {
  const files = pack(200)
  for (const cap of [1, 2, 3, 7]) {
    const windowed = DebridService.windowFiles(files, episode(files, 100), cap)
    assert.equal(windowed.length, cap)
    assert.ok(windowed.includes(episode(files, 100)), `cap ${cap} must still cover the episode`)
  }
})

test('windowing can key by something other than path when a service needs to', () => {
  const files = Array.from({ length: 100 }, (_, index) => ({ id: index, size: 1000 }))
  const windowed = DebridService.windowFiles(files, files[80], 10, file => file.id)
  assert.ok(windowed.includes(files[80]))
  assert.equal(windowed.length, 10)
})
