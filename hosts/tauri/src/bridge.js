// Injected before the page loads: implements the parts of the platform bridge
// (common/modules/bridge.js) the Tauri host supports so far. bridge.js merges
// this over its noop defaults, so anything missing here degrades gracefully.
(() => {
  const invoke = window.__TAURI__.core.invoke
  // inlined at build time by the host, so the sync getPlatformInfo contract holds
  const platformInfo = __SHIRU_PLATFORM_INFO__

  const listen = window.__TAURI__.event.listen

  // one handler per update state, replaced rather than stacked: the modal owns them
  const updateListeners = new Map()
  listen('shiru://update', (event) => {
    const { type, data } = event.payload || {}
    updateListeners.get(type)?.(data)
  })

  window.common = {
    getAppVersion: () => invoke('get_app_version'),
    getPlatformInfo: () => platformInfo,
    isWindowVisible: async () => true,
    openURI: (uri) => invoke('open_uri', { uri }).catch(() => {}),
    windowReady: () => invoke('window_ready'),
    notify: (opts) => invoke('notify', { title: opts?.title || 'zeroShiru', body: opts?.message || opts?.body }),
    pickFile: async (filters) => (await invoke('pick_file', { filters })) || '',
    pickFolder: async () => (await invoke('pick_folder')) || '',
    exportLog: () => invoke('export_log'),
    resetLog: () => invoke('reset_log'),
    setUpdateChannel: (channel) => invoke('set_update_channel', { channel: channel || 'stable' }),
    // answers 'unconfigured' until a signing key exists, which the UI treats as
    // "nothing to install" rather than as a failure
    checkForUpdates: (channel) => invoke('check_for_updates', { channel: channel || 'stable' }).catch(() => {}),
    quitAndInstall: () => invoke('quit_and_install'),
    onUpdateAvailable: (callback) => { updateListeners.set('available', callback) },
    onUpdateDownloaded: (callback) => { updateListeners.set('downloaded', callback) },
    onUpdateProgress: (callback) => { updateListeners.set('progress', callback) },
    onUpdateAborted: (callback) => { updateListeners.set('aborted', callback) },
    // deep links (shiru://, magnet:) as raw URLs; routing lives in the renderer
    onProtocol: (callback) => { listen('shiru://protocol', (event) => callback(event.payload)) }
  }

  window.desktop = {
    exit: () => invoke('app_exit'),
    isMinimized: () => invoke('window_is_minimized'),
    isFullScreen: () => invoke('window_is_fullscreen'),
    hideWindow: () => invoke('window_hide'),
    showAndFocus: () => invoke('window_show_and_focus'),
    openDevTools: () => invoke('open_devtools'),
    setUnreadCount: (count) => invoke('set_unread_count', { count: Number(count) || 0 }),
    // how the renderer is composited; stored, applied at the next launch
    getGraphics: () => invoke('get_graphics'),
    setGraphics: (mode) => invoke('set_graphics', { mode }),
    onExitIntent: (callback) => { listen('shiru://exit-intent', () => callback()) },
    setDiscordRPC: (mode) => invoke('set_discord_rpc', { mode }),
    setPresence: (data) => {
      const activity = data?.activity || {}
      invoke('set_presence', { presence: {
        details: activity.details,
        state: activity.state,
        large_image: activity.assets?.large_image,
        large_text: activity.assets?.large_text,
        small_image: activity.assets?.small_image,
        small_text: activity.assets?.small_text,
        start: activity.timestamps?.start ?? null
      } })
    },
    clearPresence: () => invoke('clear_presence')
  }

  // the frame buttons the custom titlebar drives
  window.shiruWindow = {
    minimize: () => invoke('window_minimize'),
    toggleMaximize: () => invoke('window_toggle_maximize')
  }

  // answers from a running availability check, pushed as each one lands
  const availabilityListeners = new Set()
  listen('shiru://debrid', (event) => {
    const { type, data } = event.payload || {}
    if (type === 'availability') for (const callback of availabilityListeners) callback(data.hash, data.state)
  })

  window.shiru = {
    routePlayback: (request) => invoke('route_playback', { request }),
    debrid: {
      // inlined at build time by the host, so the settings menu reads the registry synchronously
      services: __SHIRU_DEBRID_SERVICES__,
      validate: (service, apiKey) => invoke('debrid_validate', { service, apiKey }),
      listAvailability: (service, apiKey) => invoke('debrid_list_availability', { service, apiKey }),
      checkAvailability: (service, apiKey, hashes) => invoke('debrid_check_availability', { service, apiKey, hashes }),
      unknownHashes: (service, apiKey, hashes) => invoke('debrid_unknown_hashes', { service, apiKey, hashes }),
      remember: (service, apiKey, hash, state) => invoke('debrid_remember', { service, apiKey, hash, stateValue: state }),
      resolve: (service, apiKey, magnet, episode) => invoke('debrid_resolve', { service, apiKey, magnet, episode: Number.isFinite(episode) ? episode : null }),
      onAvailability: (callback) => { availabilityListeners.add(callback) }
    }
  }

  // torrent session: commands go down as invokes, state comes back on one event
  // channel fanned out per type — common/modules/bridge.js merges this over its
  // noop defaults
  const torrentListeners = new Map() // type -> Set<callback>
  listen('shiru://torrent', (event) => {
    const { type, data } = event.payload || {}
    for (const callback of torrentListeners.get(type) || []) callback(data)
  })
  const on = (type) => (callback) => {
    if (!torrentListeners.has(type)) torrentListeners.set(type, new Set())
    torrentListeners.get(type).add(callback)
  }
  /** single-slot: re-registered per playback, replacing the previous handler */
  const one = (type) => (callback) => { torrentListeners.set(type, new Set([callback])) }
  const asId = (id) => {
    // .torrent bytes cross the bridge as base64
    if (id instanceof Uint8Array || id instanceof ArrayBuffer) {
      const bytes = id instanceof ArrayBuffer ? new Uint8Array(id) : id
      let binary = ''
      for (const byte of bytes) binary += String.fromCharCode(byte)
      return { id: btoa(binary), base64: true }
    }
    return { id: String(id), base64: false }
  }

  window.torrent = {
    start: (settings) => invoke('torrent_start', { settings }),
    stream: (id) => invoke('torrent_stream', asId(id)),
    stage: (id) => invoke('torrent_stage', asId(id)),
    unload: () => invoke('torrent_unload'),
    untrack: (hash) => invoke('torrent_untrack', { hash }),
    complete: (hash) => invoke('torrent_complete', { hash }),
    rescan: () => invoke('torrent_rescan'),
    scrape: (hashes) => invoke('torrent_scrape', { hashes }),
    setPlayback: (current, external) => invoke('torrent_set_playback', { current, external: !!external }),
    launchExternal: (current) => invoke('torrent_launch_external', { current }),
    updateSettings: (settings) => invoke('torrent_update_settings', { settings }).catch(() => {}),
    onStats: on('stats'),
    onCurrentStats: on('currentStats'),
    onProgress: on('progress'),
    onFiles: on('files'),
    onLoaded: on('loaded'),
    onNotify: on('notify'),
    onExternalReady: one('externalReady'),
    onExternalWatched: one('externalWatched')
  }
})()
