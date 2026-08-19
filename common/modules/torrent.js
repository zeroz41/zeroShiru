import { files, nowPlaying as media } from '@/components/MediaHandler.svelte'
import { page } from '@/modules/navigation.js'
import { settings, debugStore } from '@/modules/settings.js'
import { cache, caches } from '@/modules/cache.js'
import { SUPPORTS } from '@/modules/support.js'
import { status } from '@/modules/networking.js'
import { writable } from 'simple-store-svelte'
import { toast } from 'svelte-sonner'
import { capitalize } from '@/modules/util.js'
import clipboard from '@/modules/lib/clipboard.js'
import { streamDebrid, debridPlayback } from '@/modules/debrid/debrid.js'
import { setHash } from '@/modules/anime/animehash.js'
import { requestPlayback } from '@/modules/playback/request.js'
import { TORRENT, ELECTRON } from '@/modules/bridge.js'
import { get } from 'svelte/store'
import Debug from 'debug'
const debug = Debug('ui:torrent')

const excludedToastMessages = ['no buffer space', 'localDescription']
const torrentRx = /(^magnet:){1}|(^[A-F\d]{8,40}$){1}|(.*\.torrent$){1}/i
let _settings

export const loadingSession = writable(true)
export const loadedTorrent = writable({})
export const stagingTorrents = writable([])
export const seedingTorrents = writable([])
export const completedTorrents = writable([])

clipboard.addEventListener('text', ({ detail }) => {
  for (const { text } of detail) {
    if (page.value !== page.WATCH_TOGETHER && torrentRx.exec(text)) {
      media.value = { torrent: true }
      add(text, null, null, true)
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

_settings = { userID: cache.cacheID, dht: !settings.value.torrentDHT, torrentUTP: !settings.value.torrentUTP, torrentPeX: !settings.value.torrentPeX, maxConns: settings.value.maxConns, downloadLimit: (settings.value.torrentSpeed * 1048576) || 0, uploadLimit: (settings.value.torrentSpeed * 1048576) || 0, torrentPort: settings.value.torrentPort || 0, dhtPort: settings.value.dhtPort || 0, torrentPersist: settings.value.torrentPersist, torrentStreamedDownload: settings.value.torrentStreamedDownload, torrentPathNew: settings.value.torrentPathNew, playerPath: settings.value.playerPath, seedingLimit: settings.value.seedingLimit, trackers: settings.value.trackers, debug: get(debugStore) }
TORRENT.portRequest(_settings).then(() => {
  setupTorrentClient()
  status.subscribe(value => TORRENT.updateNetwork(value))
  settings.subscribe(value => {
    let settingsVal = { userID: cache.cacheID, dht: !value.torrentDHT, torrentUTP: !value.torrentUTP, torrentPeX: !value.torrentPeX, maxConns: value.maxConns, downloadLimit: (value.torrentSpeed * 1048576) || 0, uploadLimit: (value.torrentSpeed * 1048576) || 0, torrentPort: value.torrentPort || 0, dhtPort: value.dhtPort || 0, torrentPersist: value.torrentPersist, torrentStreamedDownload: value.torrentStreamedDownload, torrentPathNew: value.torrentPathNew, playerPath: value.playerPath, seedingLimit: value.seedingLimit, trackers: value.trackers, debug: get(debugStore) }
    if (JSON.stringify(_settings) !== JSON.stringify(settingsVal)) {
      _settings = settingsVal
      TORRENT.updateSettings(_settings)
    }
  })

  window.addEventListener('add', (event) => add(event.detail.resolvedHash, event.detail.search, event.detail.resolvedHash)) // TODO: Circular Dependency (MediaHandler.svelte)
  TORRENT.onCrash(() => {
    console.error('Ooops! WebTorrent Crashed! A crash has been detected... The process has automatically been restarted.')
    toast.dismiss()
    toast.error('Ooops! WebTorrent Crashed!', {
      description: 'A crash has been detected... The process has automatically been restarted.',
      duration: 15000
    })
    setupTorrentClient()
  })
  TORRENT.onRequest(opts => {
    ELECTRON.showAndFocus()
    debug(`Got torrent request for:`, JSON.stringify(opts))
    add(opts.magnet, null, null, null, opts.base64)
  })

  TORRENT.onStats(detail => {
    loadedTorrent.update(() => ({ ...detail.current }))
    stagingTorrents.update(() => Array.from(new Map(detail.staging.map(torrent => [torrent.infoHash, torrent])).values()))
    seedingTorrents.update(() => Array.from(new Map(detail.seeding.map(torrent => [torrent.infoHash, torrent])).values()))
  })

  TORRENT.onFiles(_files => {
    debug(`Got files request:`, _files?.length)
    // the client announces the files of every torrent it loads, including the one restored at
    // startup, which would swap out what debrid is playing. Playing a torrent hands the player
    // back first, so this never blocks a real request
    if (debridPlayback.value) return debug('Ignoring torrent files, debrid owns playback')
    files.set(_files)
  })

  TORRENT.onLoaded(detail => {
    cache.setEntry(caches.GENERAL, 'loadedTorrent', detail)
    debug(`Got loaded request for torrent:`, detail?.infoHash)
    deduplicate(detail?.infoHash)
  })

  TORRENT.onUntrack(detail => {
    debug(`Got untrack request for torrent:`, JSON.stringify(detail))
    deduplicate(detail)
  })

  TORRENT.onStage(detail => {
    debug(`Staging torrent:`, JSON.stringify(detail))
    const torrents = cache.getEntry(caches.GENERAL, 'stagingTorrents') || []
    if (!torrents.includes(detail)) {
      cache.setEntry(caches.GENERAL, 'stagingTorrents', Array.from(new Set([...torrents, detail])))
    }
    const found = structuredClone(seedingTorrents.value.find(torrent => torrent.infoHash === detail) || completedTorrents.value.find(torrent => torrent.infoHash === detail))
    deduplicate(detail, 'seedingTorrents', 'completedTorrents')
    if (loadedTorrent.value?.infoHash === detail) loadedTorrent.update(() => ({}))
    if (found) (found.incomplete ? stagingTorrents : seedingTorrents).update(prev => [found, ...prev.filter(torrent => torrent.infoHash !== detail)])
  })

  TORRENT.onSeed(detail => {
    debug(`Seeding torrent:`, JSON.stringify(detail))
    const torrents = cache.getEntry(caches.GENERAL, 'seedingTorrents') || []
    if (!torrents.includes(detail)) cache.setEntry(caches.GENERAL, 'seedingTorrents', Array.from(new Set([...torrents, detail])))
    deduplicate(detail, 'stagingTorrents', 'completedTorrents')
  })

  TORRENT.onComplete(detail => {
    debug(`Completed torrent:`, JSON.stringify(detail))
    const torrents = cache.getEntry(caches.GENERAL, 'completedTorrents') || []
    if (!torrents.includes(detail?.infoHash)) cache.setEntry(caches.GENERAL, 'completedTorrents', Array.from(new Set([...torrents, detail.infoHash])))
    deduplicate(detail?.infoHash, 'stagingTorrents', 'seedingTorrents')
    if (loadedTorrent.value?.infoHash === detail.infoHash) loadedTorrent.update(() => ({}))
    completedTorrents.update(prev => [detail, ...prev.filter(torrent => torrent.infoHash !== detail.infoHash)])
  })

  TORRENT.onCompletedStats(detail => {
    debug('Got completed stats request')
    completedTorrents.update(torrents => [...Array.from(new Map(detail.map(torrent => [torrent.infoHash, torrent])).values()), ...torrents])
    loadingSession.set(false)
  })

  TORRENT.onNotify(notify)
})

export async function add(torrentID, search, hash, magnet, base64 = false) {
  if (torrentID) {
    debug('Adding torrent', JSON.stringify({ torrentID, search, hash, magnet }))
    files.set([])
    page.navigateTo(page.PLAYER)
    media.value = search ? { media: (search.media || media.value?.media), episode: (search.episode || media.value?.episode), ...(media.value?.torrent ? { torrent: true } : { feed: true }) } : { torrent: true }
    requestPlayback(search) // an episode named here outranks the watch-status guess made once the files land
    if (hash && search) setHash(hash, { mediaId: search.media?.id, episode: search.episode, client: true })
    if (SUPPORTS.isAndroid && !settings.value.enableExternal) document.querySelector('.content-wrapper').requestFullscreen() // this WILL not work with auto-select torrents due to permissions check.
    if (await streamDebrid(torrentID, hash, search)) return
    TORRENT.stream(torrentID, (hash === torrentID && torrentID) || false, magnet, base64)
  }
}
export async function stage(torrentID, search, hash) {
  if (torrentID) {
    debug('Pre-Adding torrent', JSON.stringify({ torrentID, search, hash }))
    if (hash && search) setHash(hash, { mediaId: search.media?.id, episode: search.episode, client: true })
    TORRENT.stage(torrentID, (hash === torrentID && torrentID) || false)
    if (hash) {
      const existingTorrent = seedingTorrents.value.find(torrent => torrent.infoHash === hash) || completedTorrents.value.find(torrent => torrent.infoHash === hash)
      if (existingTorrent) {
        stagingTorrents.update(list => [...list, existingTorrent])
        seedingTorrents.update(torrents => torrents.filter(torrent => torrent.infoHash !== hash))
        completedTorrents.update(torrents => torrents.filter(torrent => torrent.infoHash !== hash))
      }
    }
  }
}
export async function unload(torrent, hash, force = false) {
  if (torrent) {
    debug('Unloading torrent', JSON.stringify({ torrent, hash }))
    TORRENT.unload({ torrent, hash })
  } else if (force) {
    files.value = []
    media.value = { ...media.value, display: true } // set display to true to allow the 'Last Watched' button to remain on the SideBar.
    TORRENT.unload(null) // this will not override the cached loadedTorrent, we rely on users to enable disableStartupTorrent if they don't want to load the previous torrent when the app starts.
  }
}
export async function untrack(hash) {
  if (hash) {
    debug('Untracking torrent', hash)
    if (loadedTorrent.value?.infoHash === hash) {
      files.value = []
      media.value = { ...media.value, display: true } // set display to true to allow the 'Last Watched' button to remain on the SideBar.
    }
    TORRENT.untrack(hash)
  }
}
export async function complete(hash) {
  if (hash) {
    debug('Stopping Seeding torrent', hash)
    TORRENT.complete(hash)
  }
}
export async function reannounce(hash) {
  if (hash) {
    debug('Requesting reannounce for torrent', hash)
    TORRENT.reannounce(hash)
  }
}

function deduplicate(hash, ..._caches) {
  if (!hash) return
  const cacheList = _caches.length ? _caches : ['stagingTorrents', 'seedingTorrents', 'completedTorrents']
  for (const cacheName of cacheList) {
    const list = cache.getEntry(caches.GENERAL, cacheName) || []
    const filtered = list.filter(h => h !== hash)
    if (filtered.length !== list.length) {
      debug(`Detected duplicate torrent in: ${cacheName}`)
      cache.setEntry(caches.GENERAL, cacheName, filtered)
    }
  }
  if (_caches.includes('stagingTorrents') || !_caches.length) stagingTorrents.update(arr => arr.filter(torrent => torrent.infoHash !== hash))
  if (_caches.includes('seedingTorrents') || !_caches.length) seedingTorrents.update(arr => arr.filter(torrent => torrent.infoHash !== hash))
  if (_caches.includes('completedTorrents') || !_caches.length) completedTorrents.update(arr => arr.filter(torrent => torrent.infoHash !== hash))
}

function setupTorrentClient() {
  loadingSession.set(true)
  loadedTorrent.value = {}
  stagingTorrents.value = []
  seedingTorrents.value = []
  completedTorrents.value = []
  if (!settings.value.disableStartupTorrent) TORRENT.restoreSession(cache.getEntry(caches.GENERAL, 'stagingTorrents').filter(Boolean), cache.getEntry(caches.GENERAL, 'seedingTorrents').filter(Boolean), cache.getEntry(caches.GENERAL, 'completedTorrents').filter(Boolean), cache.getEntry(caches.GENERAL, 'loadedTorrent'))
  else {
    debug(`Unloading torrent(s) from previous session`)
    TORRENT.unload(cache.getEntry(caches.GENERAL, 'loadedTorrent'))
    const unloadedCompleted = Array.from(new Set([...(cache.getEntry(caches.GENERAL, 'completedTorrents') || []), ...(cache.getEntry(caches.GENERAL, 'seedingTorrents') || []), ...(cache.getEntry(caches.GENERAL, 'stagingTorrents') || [])])).filter(Boolean)
    cache.setEntry(caches.GENERAL, 'loadedTorrent', {})
    cache.setEntry(caches.GENERAL, 'completedTorrents', unloadedCompleted)
    cache.setEntry(caches.GENERAL, 'stagingTorrents', [])
    cache.setEntry(caches.GENERAL, 'seedingTorrents', [])
    TORRENT.restoreSession(null, null, unloadedCompleted)
  }
}

function notify(type, detail) {
  debug(`${capitalize(type)}:`, detail.message || JSON.stringify(detail))
  if (type === 'info' || settings.value.toasts.includes('All') || settings.value.toasts.includes('Warnings')) {
    for (const exclude of excludedToastMessages) {
      if ((detail.message || detail)?.toLowerCase()?.includes(exclude)) return
    }
    if (type === 'warn') toast.warning(`Torrent Warning`, { description: '' + (detail.message || detail) })
    else if (type === 'error') toast.error(`Torrent Error`, { description: '' + (detail.message || detail) })
    else toast(`Torrent ${capitalize(type)}`, { description: '' + (detail.message || detail) })
  }
}