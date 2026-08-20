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

/** @type {import('simple-store-svelte').Writable<{ mode: string, modes: string[], overridden: boolean, effective?: string, failedStarts?: number }>} */
export const graphics = writable({ mode: 'auto', modes: [], overridden: false })

/** What each mode means, for the settings screen. */
export const graphicsModes = {
  auto: 'Automatic — the GPU path, dropped only after a launch that failed to draw',
  'no-dmabuf': 'No DMABUF — for a window that never appears, or renders black',
  safe: 'Safe — no DMABUF and no compositing, slowest and most compatible'
}

/**
 * What Automatic has settled on, or null when nothing needs saying. Auto falling back is
 * invisible otherwise, and it costs real smoothness: every composited frame goes through
 * the CPU, so the app feels slow for a reason the user cannot see.
 * @param {{ mode?: string, effective?: string, failedStarts?: number }} value
 * @returns {string | null}
 */
export function graphicsFallbackNotice ({ mode, effective, failedStarts } = {}) {
  if (mode !== 'auto' || !failedStarts || !effective || effective === 'auto') return null
  const launches = failedStarts === 1 ? 'A previous launch' : `${failedStarts} launches in a row`
  return `${launches} failed to draw a window, so Automatic has dropped to ${graphicsModes[effective]?.split(' — ')[0] || effective}. That costs smoothness — pick Automatic again after fixing the driver, or once a launch works it clears itself.`
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
