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
  auto: 'Automatic — the GPU path, or the safe one on a driver known to need it',
  'gpu-no-gbm': 'GPU without GBM — keeps accelerated compositing, skips the buffer call NVIDIA rejects',
  'no-dmabuf': 'No DMABUF — frames go through shared memory; slower, works everywhere',
  safe: 'Safe — no DMABUF and no compositing, slowest and most compatible'
}

/** The modes that composite on the GPU, for wording that depends on it. */
const accelerated = new Set(['gpu', 'gpu-no-gbm'])

/**
 * What Automatic has settled on, or null when nothing needs saying. Auto falling back is
 * invisible otherwise, and it costs real smoothness: every composited frame goes through
 * the CPU, so the app feels slow for a reason the user cannot see.
 * @param {{ mode?: string, effective?: string, failedStarts?: number }} value
 * @returns {string | null}
 */
export function graphicsFallbackNotice ({ mode, effective, failedStarts } = {}) {
  if (!effective || effective === 'gpu' || effective === mode) return null
  const name = graphicsModes[effective]?.split(' — ')[0] || effective
  if (failedStarts) {
    const launches = failedStarts === 1 ? 'A previous launch' : `${failedStarts} launches in a row`
    return `${launches} could not draw a window, so this is running as ${name} regardless of the setting. It clears itself the moment a launch draws.`
  }
  if (mode !== 'auto') return null
  // auto took the safe rung on purpose, which costs real smoothness and is worth saying:
  // every composited frame goes through shared memory instead of the GPU
  return !accelerated.has(effective)
    ? `Automatic is using ${name}: this graphics driver rejects the buffers accelerated compositing needs, and a black window is not worth the frame rate. GPU without GBM is the narrower workaround — if it cannot draw either, the next launch comes back here on its own.`
    : null
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
