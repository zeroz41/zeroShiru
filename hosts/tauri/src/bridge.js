// Injected before the page loads: implements the parts of the platform bridge
// (common/modules/bridge.js) the Tauri host supports so far. bridge.js merges
// this over its noop defaults, so anything missing here degrades gracefully.
(() => {
  const invoke = window.__TAURI__.core.invoke
  // inlined at build time by the host, so the sync getPlatformInfo contract holds
  const platformInfo = __SHIRU_PLATFORM_INFO__

  const listen = window.__TAURI__.event.listen

  window.common = {
    getAppVersion: () => invoke('get_app_version'),
    getPlatformInfo: () => platformInfo,
    isWindowVisible: async () => true,
    openURI: (uri) => invoke('open_uri', { uri }).catch(() => {}),
    windowReady: () => invoke('window_ready'),
    notify: (opts) => invoke('notify', { title: opts?.title || 'Shiru', body: opts?.message || opts?.body }),
    pickFile: async (filters) => (await invoke('pick_file', { filters })) || '',
    pickFolder: async () => (await invoke('pick_folder')) || '',
    handleProtocol: () => {} // URLs arrive via the shiru://protocol event below
  }

  // deep links (shiru://, magnet:) land here; the frontend's protocol map decides
  window.__shiruProtocol = (callback) => { listen('shiru://protocol', (event) => callback(event.payload)) }

  window.electron = {
    exit: () => invoke('app_exit'),
    isMinimized: () => invoke('window_is_minimized'),
    isFullScreen: () => invoke('window_is_fullscreen'),
    hideWindow: () => invoke('window_hide'),
    showAndFocus: () => invoke('window_show_and_focus'),
    openDevTools: () => invoke('open_devtools'),
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

  window.shiru = {
    routePlayback: (request) => invoke('route_playback', { request }),
    torrent: {
      add: (id) => invoke('torrent_add', { id }),
      metadata: (infoHash) => invoke('torrent_metadata', { infoHash }),
      selectFile: (infoHash, index) => invoke('torrent_select_file', { infoHash, index }),
      playbackSource: (infoHash, index) => invoke('torrent_playback_source', { infoHash, index }),
      status: (infoHash) => invoke('torrent_status', { infoHash }),
      pause: (infoHash) => invoke('torrent_pause', { infoHash }),
      resume: (infoHash) => invoke('torrent_resume', { infoHash }),
      remove: (infoHash) => invoke('torrent_remove', { infoHash }),
      onStatus: (callback) => { listen('shiru://torrent-status', (event) => callback(event.payload)) }
    },
    debrid: {
      validate: (service, apiKey) => invoke('debrid_validate', { service, apiKey }),
      checkAvailability: (service, apiKey, hashes) => invoke('debrid_check_availability', { service, apiKey, hashes }),
      resolve: (service, apiKey, magnet) => invoke('debrid_resolve', { service, apiKey, magnet })
    }
  }
})()
