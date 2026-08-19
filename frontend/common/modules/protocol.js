// shiru:// and magnet: routing, entirely renderer-side. Hosts hand raw URLs to
// COMMON.onProtocol (deep links, second instances, OAuth redirects); modules
// register for the semantic events they care about.
import { COMMON, DESKTOP } from '@/modules/bridge.js'
import Debug from 'debug'
const debug = Debug('ui:protocol')

const protocolRx = /shiru:\/\/([a-z0-9]+)\/?(.*)/i

const listeners = {
  torrent: new Set(),
  providerToken: new Set(),
  requestPage: new Set(),
  requestModal: new Set(),
  requestPlay: new Set(),
  lobbyInvite: new Set()
}

/** @param {keyof typeof listeners} type */
const register = type => callback => { listeners[type].add(callback) }
const dispatch = (type, ...args) => { for (const callback of listeners[type]) callback(...args) }

/** magnet:… or .torrent payloads that should start playing */
export const onTorrentRequest = register('torrent')
/** (provider, opts) OAuth tokens: ('anilist', { token }) / ('myanimelist', { code, state }) */
export const onProviderToken = register('providerToken')
export const onRequestPage = register('requestPage')
export const onRequestModal = register('requestModal')
export const onRequestPlay = register('requestPlay')
export const onLobbyInvite = register('lobbyInvite')

// schema: shiru://key/value
const protocolMap = {
  alauth: line => {
    let token = line.split('access_token=')[1]?.split('&token_type')[0]
    if (!token) return
    if (token.endsWith('/')) token = token.slice(0, -1)
    dispatch('providerToken', 'anilist', { token })
  },
  malauth: line => {
    let code = line.split('code=')[1]?.split('&state')[0]
    let state = line.split('&state=')[1]
    if (!code || !state) return
    if (code.endsWith('/')) code = code.slice(0, -1)
    if (state.endsWith('/')) state = state.slice(0, -1)
    if (state.includes('%')) state = decodeURIComponent(state)
    dispatch('providerToken', 'myanimelist', { code, state })
  },
  anime: id => dispatch('requestModal', 'anime_details', { id }),
  malanime: id => dispatch('requestModal', 'anime_details', { id, isMal: true }),
  torrent: magnet => dispatch('torrent', magnet),
  search: id => dispatch('requestPlay', { id }),
  w2g: link => dispatch('lobbyInvite', link),
  schedule: () => dispatch('requestPage', 'schedule'),
  show: () => DESKTOP.showAndFocus()
}

/** @param {string} text - a raw URL: magnet:…, shiru://…, or noise to ignore */
export function handleProtocol (text) {
  if (!text) return
  if (text.startsWith('magnet:')) return dispatch('torrent', text)
  const match = text.match(protocolRx)
  if (!match) return
  debug(`protocol: ${match[1]}`)
  protocolMap[match[1]]?.(match[2])
}

COMMON.onProtocol(handleProtocol)
