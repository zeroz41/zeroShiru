// Torrent UI layer. The Rust session owns all torrent state and pushes a full
// snapshot after every change; the stores here are projections of that snapshot
// and nothing more — no bookkeeping, no caching, no session restore logic.
import { files, nowPlaying as media } from '@/components/MediaHandler.svelte'
import { page } from '@/modules/navigation.js'
import { settings } from '@/modules/settings.js'
import { SUPPORTS } from '@/modules/support.js'
import { writable } from 'simple-store-svelte'
import { toast } from 'svelte-sonner'
import { capitalize } from '@/modules/util.js'
import clipboard from '@/modules/lib/clipboard.js'
import { streamDebrid, debridPlayback, debridTransport } from '@/modules/debrid/debrid.js'
import { torrentToast } from '@/modules/lib/torrent-toasts.js'
import { setHash } from '@/modules/anime/animehash.js'
import { requestPlayback } from '@/modules/playback/request.js'
import { onTorrentRequest } from '@/modules/protocol.js'
import { TORRENT, DESKTOP } from '@/modules/bridge.js'
import Debug from 'debug'
const debug = Debug('ui:torrent')

const torrentRx = /(^magnet:){1}|(^[A-F\d]{8,40}$){1}|(.*\.torrent$){1}/i

export const loadingSession = writable(true)
export const loadedTorrent = writable({})
export const stagingTorrents = writable([])
export const seedingTorrents = writable([])
export const completedTorrents = writable([])

/** the session settings object the Rust side deserializes */
const torrentSettings = value => ({
  dht: !value.torrentDHT,
  torrentUTP: !value.torrentUTP,
  torrentPeX: !value.torrentPeX,
  maxConns: value.maxConns,
  downloadLimit: (value.torrentSpeed * 1048576) || 0,
  uploadLimit: (value.torrentSpeed * 1048576) || 0,
  torrentPort: value.torrentPort || 0,
  dhtPort: value.dhtPort || 0,
  torrentPersist: value.torrentPersist,
  torrentStreamedDownload: value.torrentStreamedDownload,
  torrentPathNew: value.torrentPathNew,
  playerPath: value.playerPath,
  seedingLimit: value.seedingLimit,
  disableStartupTorrent: value.disableStartupTorrent,
  trackers: value.trackers
})

clipboard.addEventListener('text', ({ detail }) => {
  for (const { text } of detail) {
    if (page.value !== page.WATCH_TOGETHER && torrentRx.exec(text)) {
      media.value = { torrent: true }
      add(text)
    }
  }
})
if (!SUPPORTS.isAndroid) {
  clipboard.addEventListener('files', async ({ detail }) => {
    for (const file of detail) {
      if (file.name.endsWith('.torrent')) {
        media.value = { torrent: true }
        add(new Uint8Array(await file.arrayBuffer()))
      }
    }
  })
}

let _settings = torrentSettings(settings.value)
TORRENT.start(_settings).then(() => {
  settings.subscribe(value => {
    const next = torrentSettings(value)
    if (JSON.stringify(_settings) !== JSON.stringify(next)) {
      _settings = next
      TORRENT.updateSettings(next)
    }
  })

  window.addEventListener('add', (event) => add(event.detail.resolvedHash, event.detail.search, event.detail.resolvedHash)) // TODO: Circular Dependency (MediaHandler.svelte)
  onTorrentRequest(magnet => {
    DESKTOP.showAndFocus()
    debug('Torrent request via protocol:', typeof magnet === 'string' ? magnet : '.torrent data')
    media.value = { torrent: true }
    add(magnet)
  })

  TORRENT.onStats(snapshot => {
    loadedTorrent.value = snapshot.current || {}
    stagingTorrents.value = snapshot.staging || []
    seedingTorrents.value = snapshot.seeding || []
    completedTorrents.value = snapshot.completed || []
    loadingSession.set(false)
  })

  TORRENT.onLoaded(detail => {
    debug('Loaded torrent:', detail?.infoHash)
    if (detail) loadedTorrent.value = { infoHash: detail.infoHash, name: detail.name, magnetURI: detail.magnet }
  })

  TORRENT.onFiles(_files => {
    debug('Got files:', _files?.length)
    // debrid owns playback while its stream is active; a torrent finishing
    // metadata in the background must not steal the player
    if (debridPlayback.value) return debug('Ignoring torrent files, debrid owns playback')
    files.set(_files)
  })

  TORRENT.onNotify(notify)
})

export async function add (torrentID, search, hash) {
  if (!torrentID) return
  debug('Adding torrent', JSON.stringify({ torrentID: typeof torrentID === 'string' ? torrentID : '.torrent data', search, hash }))
  files.set([])
  page.navigateTo(page.PLAYER)
  media.value = search ? { media: (search.media || media.value?.media), episode: (search.episode || media.value?.episode), ...(media.value?.torrent ? { torrent: true } : { feed: true }) } : { torrent: true }
  requestPlayback(search) // an episode named here outranks the watch-status guess made once the files land
  if (hash && search) setHash(hash, { mediaId: search.media?.id, episode: search.episode, client: true })
  if (SUPPORTS.isAndroid && !settings.value.enableExternal) document.querySelector('.content-wrapper').requestFullscreen()
  if (await streamDebrid(torrentID, hash, search)) return
  TORRENT.stream(torrentID)
}

export async function stage (torrentID, search, hash) {
  if (!torrentID) return
  debug('Staging torrent', JSON.stringify({ torrentID: typeof torrentID === 'string' ? torrentID : '.torrent data', search, hash }))
  if (hash && search) setHash(hash, { mediaId: search.media?.id, episode: search.episode, client: true })
  TORRENT.stage(torrentID)
}

export async function unload () {
  debug('Unloading current torrent')
  files.value = []
  media.value = { ...media.value, display: true } // keep the 'Last Watched' button on the SideBar
  TORRENT.unload()
}

export async function untrack (hash) {
  if (!hash) return
  debug('Untracking torrent', hash)
  if (loadedTorrent.value?.infoHash === hash) {
    files.value = []
    media.value = { ...media.value, display: true }
  }
  TORRENT.untrack(hash)
}

export async function complete (hash) {
  if (!hash) return
  debug('Stopping seeding for torrent', hash)
  TORRENT.complete(hash)
}

function notify (detail) {
  const type = detail?.type || 'info'
  debug(`${capitalize(type)}:`, detail?.message)
  // while debrid is the transport the torrent lane's failures are not the user's
  // weather — they stay in the log. See lib/torrent-toasts.js for the rule
  const debridActive = debridPlayback.value || Boolean(debridTransport.value?.only)
  if (torrentToast(type, { toasts: settings.value.toasts, debridActive })) {
    if (type === 'warn') toast.warning('Torrent Warning', { description: '' + detail.message })
    else if (type === 'error') toast.error('Torrent Error', { description: '' + detail.message })
    else toast(`Torrent ${capitalize(type)}`, { description: '' + detail.message })
  }
}
