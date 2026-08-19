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
  setDoH: noopVoid,
  getAngle: async () => 'default',
  setAngle: noopVoid,
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

export const TORRENT = { ...torrentDefaults, ...window.torrent }
export const COMMON = { ...commonDefaults, ...window.common }
export const ANDROID = { ...androidDefaults, ...window.android }
export const DESKTOP = { ...desktopDefaults, ...window.desktop }
