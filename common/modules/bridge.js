// The host seam. This is the ONLY file in common/ that touches a host API:
// hosts (Tauri desktop/Android, TV bootstraps) inject window.torrent /
// window.common / window.android / window.desktop, and everything merges over
// noop defaults so a host may implement its surface incrementally.
const noopVoid = () => {}
const noopAsyncVoid = async () => {}
const noopAsyncBool = async () => false
const noopAsyncString = async () => ''

// the torrent session lives in the Rust core; commands go down, state is pushed back
const torrentDefaults = {
  /** boots the session with the user's torrent settings; resolves when ready */
  start: noopAsyncVoid,
  /** load a magnet / hash / .torrent URL / .torrent bytes for playback */
  stream: noopAsyncVoid,
  /** pre-download in the background without touching playback */
  stage: noopAsyncVoid,
  /** stop playback; finished torrents keep seeding */
  unload: noopAsyncVoid,
  /** forget a torrent completely, data included */
  untrack: noopAsyncVoid,
  /** stop seeding but keep files */
  complete: noopAsyncVoid,
  /** refresh the pushed snapshot */
  rescan: noopAsyncVoid,
  /** seeder/leecher counts for a list of info hashes */
  scrape: async (hashes) => [],
  /** tell the engine which file the player opened */
  setPlayback: noopVoid,
  /** open the current file in the configured external player */
  launchExternal: noopVoid,
  updateSettings: noopVoid,
  onStats: noopVoid,
  onCurrentStats: noopVoid,
  onProgress: noopVoid,
  onFiles: noopVoid,
  onLoaded: noopVoid,
  onNotify: noopVoid,
  onExternalReady: noopVoid,
  onExternalWatched: noopVoid
}

const commonDefaults = {
  getAppVersion: noopAsyncString,
  getPlatformInfo: () => ({ platform: '', arch: '', development: false, capabilities: {} }),
  getDeviceInfo: noopAsyncVoid,
  exportLog: noopAsyncVoid,
  resetLog: noopAsyncVoid,
  notify: noopVoid,
  windowReady: noopVoid,
  isWindowVisible: noopAsyncBool,
  openURI: noopAsyncVoid,
  pickFile: noopAsyncString,
  pickFolder: noopAsyncString,
  linkAccount: noopAsyncVoid,
  /** raw shiru:// and magnet: URLs; routing lives in modules/protocol.js */
  onProtocol: noopVoid,
  /** @param {'stable' | 'nightly'} channel */
  setUpdateChannel: (channel = 'stable') => {},
  /** @param {'stable' | 'nightly'} channel */
  checkForUpdates: (channel = 'stable') => {},
  quitAndInstall: noopVoid,
  onUpdateAvailable: noopVoid,
  onUpdateDownloaded: noopVoid,
  onUpdateProgress: noopVoid,
  onUpdateAborted: noopVoid
}

const androidDefaults = {
  minimize: noopVoid,
  showSplash: noopVoid,
  toast: noopAsyncVoid,
  onBackButton: noopVoid,
  hideStatusBar: noopVoid,
  /** @param {'LIGHT' | 'DARK'} style */
  setSystemStyle: (style = 'LIGHT') => {},
  requestFileAccess: async () => ({ granted: true }),
  launchExternal: noopAsyncVoid
}

const desktopDefaults = {
  exit: noopVoid,
  /**
   * How the renderer is composited, for stacks where the fast path fails.
   * @returns {Promise<{ mode: string, modes: string[], overridden: boolean }>}
   */
  getGraphics: async () => ({ mode: 'auto', modes: [], overridden: false }),
  /** Stored for the next launch: compositing is decided before a window exists. */
  setGraphics: noopAsyncVoid,
  isMinimized: noopAsyncBool,
  isFullScreen: noopAsyncBool,
  onMinimize: noopVoid,
  onFullScreen: noopVoid,
  hideWindow: noopVoid,
  showAndFocus: noopVoid,
  onExitIntent: noopVoid,
  openDevTools: noopVoid,
  setUnreadCount: noopVoid,
  setDiscordRPC: noopVoid,
  setPresence: noopVoid,
  clearPresence: noopVoid,
  getYouTube: async () => 'https://www.youtube-nocookie.com'
}

// the debrid layer lives in the Rust core: providers, availability memory, the
// account listing, rate limits and pack picking. The frontend asks and renders.
const debridDefaults = {
  /** selectable services as plain data, in menu order; the host inlines them */
  services: [],
  /** verify the key and that the account can stream; resolves to { username, expires } */
  validate: async (service, apiKey) => ({ username: '' }),
  /** what the account itself holds, the free badge source */
  listAvailability: async (service, apiKey) => ({ answers: {}, names: {} }),
  /** ask about releases; answers also arrive one at a time via onAvailability */
  checkAvailability: async (service, apiKey, hashes) => ({ answers: {}, names: {}, busy: false }),
  /** the given hashes nothing is known about yet */
  unknownHashes: async (service, apiKey, hashes) => [],
  /** record an answer the app proved itself, e.g. by playing the release */
  remember: noopAsyncVoid,
  /** magnet -> player-ready files; `episode` picks the right one out of a pack */
  resolve: async (service, apiKey, magnet, episode) => ({ hash: '', name: '', files: [] }),
  /** fires per answer as a check goes, so badges fill in as they land */
  onAvailability: noopVoid
}

export const TORRENT = { ...torrentDefaults, ...window.torrent }
export const COMMON = { ...commonDefaults, ...window.common }
export const ANDROID = { ...androidDefaults, ...window.android }
export const DESKTOP = { ...desktopDefaults, ...window.desktop }
export const DEBRID = { ...debridDefaults, ...window.shiru?.debrid }
