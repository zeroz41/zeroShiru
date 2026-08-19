// How the renderer is composited. WebKitGTK's fast path fails on some Linux stacks —
// NVIDIA under Wayland most often — and the window never appears, so this has to be
// changeable from inside the app that failed to draw... which is why the host also
// honours SHIRU_GRAPHICS: when the window never opens, the environment variable is
// the only way in.
//
// The host owns the list and the stored value; this is just what the settings screen
// renders from.
import { writable } from 'simple-store-svelte'
import { DESKTOP } from '@/modules/bridge.js'

/** @type {import('simple-store-svelte').Writable<{ mode: string, modes: string[], overridden: boolean }>} */
export const graphics = writable({ mode: 'auto', modes: [], overridden: false })

/** What each mode means, for the settings screen. */
export const graphicsModes = {
  auto: 'Automatic — the fallback is used only on stacks known to need it',
  'no-dmabuf': 'No DMABUF — for a window that never appears, or renders black',
  safe: 'Safe — no DMABUF and no compositing, slowest and most compatible'
}

/**
 * Stores a mode for the next launch. It cannot take effect now: compositing is
 * decided before the window exists.
 * @param {string} mode
 */
export async function setGraphicsMode (mode) {
  await DESKTOP.setGraphics(mode)
  graphics.update(current => ({ ...current, mode }))
}
