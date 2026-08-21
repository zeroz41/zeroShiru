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

  // Whatever breaks before the app bundle can listen for it — a module that throws at
  // import time leaves a blank window and, until now, an empty log. The renderer takes
  // these over the moment it is running (modules/lib/diagnostics.js), and stops these.
  const bootLog = (level, scope, message) => {
    invoke('log_renderer', { entries: [{ level, scope, message: String(message ?? '') }] }).catch(() => {})
  }
  const onBootError = (event) => bootLog('error', 'boot', event?.error?.stack || event?.message || 'unknown error')
  const onBootRejection = (event) => bootLog('error', 'boot', event?.reason?.stack || event?.reason || 'unhandled rejection')
  window.addEventListener('error', onBootError)
  window.addEventListener('unhandledrejection', onBootRejection)
  bootLog('info', 'bridge', 'host bridge injected')
  window.__SHIRU_BOOT_LOG__ = {
    stop: () => {
      window.removeEventListener('error', onBootError)
      window.removeEventListener('unhandledrejection', onBootRejection)
    }
  }

  // remote art goes through the host's capped disk cache. The scheme's shape is a
  // platform fact: WebKit and WKWebView serve custom schemes as-is, WebView2 maps
  // them onto http://<scheme>.localhost
  const mediaBase = platformInfo.platform === 'windows' ? 'http://shiru-media.localhost/' : 'shiru-media://localhost/'
  window.common = {
    getAppVersion: () => invoke('get_app_version'),
    getPlatformInfo: () => platformInfo,
    mediaSrc: (url) => typeof url === 'string' && /^https?:\/\//.test(url) ? mediaBase + encodeURIComponent(url) : url,
    isWindowVisible: async () => true,
    openURI: (uri) => invoke('open_uri', { uri }).catch(() => {}),
    windowReady: () => invoke('window_ready'),
    notify: (opts) => invoke('notify', { title: opts?.title || 'zeroShiru', body: opts?.message || opts?.body }),
    pickFile: async (filters) => (await invoke('pick_file', { filters })) || '',
    pickFolder: async () => (await invoke('pick_folder')) || '',
    exportLog: () => invoke('export_log'),
    resetLog: () => invoke('reset_log'),
    // page diagnostics into the same log everything else writes to, in batches
    log: (entries) => invoke('log_renderer', { entries }).catch(() => {}),
    setUpdateChannel: (channel) => invoke('set_update_channel', { channel: channel || 'stable' }),
    // answers 'unconfigured' until a signing key exists, which the UI treats as
    // "nothing to install" rather than as a failure
    checkForUpdates: (channel) => invoke('check_for_updates', { channel: channel || 'stable' }).catch(() => {}),
    quitAndInstall: () => invoke('quit_and_install'),
    onUpdateAvailable: (callback) => { updateListeners.set('available', callback) },
    onUpdateDownloaded: (callback) => { updateListeners.set('downloaded', callback) },
    onUpdateProgress: (callback) => { updateListeners.set('progress', callback) },
    onUpdateAborted: (callback) => { updateListeners.set('aborted', callback) },
    // is there a connection? asked natively because a webview may only ask a
    // connectivity endpoint no-cors, and an opaque answer cannot tell a working
    // link from a captive portal answering for it
    probeNetwork: (timeoutMs) => invoke('probe_network', { timeoutMs }),
    // an http(s) request made by the host rather than the page: extensions scrape sites that
    // send no CORS headers, which the webview may send but never read. Public destinations
    // only — the guard lives in the core, not here
    request: (request) => invoke('http_request', { request }),
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
    onExitIntent: (callback) => {
      listen('shiru://exit-intent', () => {
        // the host closes the window itself if nothing takes the close, so a renderer that is
        // wedged or has no handler can never trap the app open. Acknowledging AFTER the callback
        // means a handler that throws leaves that fallback armed, which is the point of it
        callback()
        invoke('exit_intent_ack')
      })
    },
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
    if (type === 'availability') for (const callback of availabilityListeners) callback(data.hash, data.state, data.requestId)
  })

  window.shiru = {
    routePlayback: (request) => invoke('route_playback', { request }),
    debrid: {
      // inlined at build time by the host, so the settings menu reads the registry synchronously
      services: __SHIRU_DEBRID_SERVICES__,
      validate: (service, apiKey) => invoke('debrid_validate', { service, apiKey }),
      listAvailability: (service, apiKey) => invoke('debrid_list_availability', { service, apiKey }),
      checkAvailability: (service, apiKey, hashes, requestId) => invoke('debrid_check_availability', { service, apiKey, hashes, requestId }),
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
