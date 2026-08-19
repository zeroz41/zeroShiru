// The renderer-side deep-link router: every shiru:// key and magnet: URLs land
// on the right semantic listener with the right payload.
import { test, beforeEach } from 'bun:test'
import assert from 'node:assert/strict'
import {
  handleProtocol, onTorrentRequest, onProviderToken, onRequestPage,
  onRequestModal, onRequestPlay, onLobbyInvite
} from '@/modules/protocol.js'

let seen
beforeEach(() => { seen = [] })

// listeners registered once; they append into the current test's log
onTorrentRequest(magnet => seen.push(['torrent', magnet]))
onProviderToken((provider, opts) => seen.push(['token', provider, opts]))
onRequestPage(name => seen.push(['page', name]))
onRequestModal((name, opts) => seen.push(['modal', name, opts]))
onRequestPlay(opts => seen.push(['play', opts]))
onLobbyInvite(link => seen.push(['lobby', link]))

test('magnet links dispatch as torrent requests', () => {
  const magnet = 'magnet:?xt=urn:btih:cab1a8cd6ea5d193fd4ea88b8e02b3e5e53e0dcb'
  handleProtocol(magnet)
  assert.deepEqual(seen, [['torrent', magnet]])
})

test('shiru://torrent carries the magnet through', () => {
  handleProtocol('shiru://torrent/magnet:?xt=urn:btih:abc')
  assert.deepEqual(seen, [['torrent', 'magnet:?xt=urn:btih:abc']])
})

test('an AniList OAuth redirect yields a trimmed token', () => {
  handleProtocol('shiru://alauth/#access_token=tok123/&token_type=Bearer')
  assert.deepEqual(seen, [['token', 'anilist', { token: 'tok123' }]])
})

test('a MAL OAuth redirect yields code and decoded state', () => {
  handleProtocol('shiru://malauth/?code=c0de&state=st%20ate')
  assert.deepEqual(seen, [['token', 'myanimelist', { code: 'c0de', state: 'st ate' }]])
})

test('a MAL redirect missing its state dispatches nothing', () => {
  handleProtocol('shiru://malauth/?code=c0de')
  assert.deepEqual(seen, [])
})

test('anime and malanime open the details modal', () => {
  handleProtocol('shiru://anime/123')
  handleProtocol('shiru://malanime/456')
  assert.deepEqual(seen, [
    ['modal', 'anime_details', { id: '123' }],
    ['modal', 'anime_details', { id: '456', isMal: true }]
  ])
})

test('search plays, w2g invites, schedule navigates', () => {
  handleProtocol('shiru://search/789')
  handleProtocol('shiru://w2g/lobby-code')
  handleProtocol('shiru://schedule/')
  assert.deepEqual(seen, [
    ['play', { id: '789' }],
    ['lobby', 'lobby-code'],
    ['page', 'schedule']
  ])
})

test('unknown keys, junk, and empty input dispatch nothing', () => {
  handleProtocol('shiru://nonsense/whatever')
  handleProtocol('https://example.com/not-a-deep-link')
  handleProtocol('')
  handleProtocol(undefined)
  assert.deepEqual(seen, [])
})
