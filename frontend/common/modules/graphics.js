// How the renderer is composited. WebKitGTK's DMA-BUF renderer fails on some Linux
// stacks — NVIDIA under Wayland most often — and the window never appears, so this has
// to be changeable from inside the app that failed to draw... which is why the host also
// honours SHIRU_GRAPHICS: when the window never opens, the environment variable is
// the only way in.
//
// The host owns the list, the stored value and the ladder it walks; this is just what
// the settings screen renders from.
import { writable } from 'simple-store-svelte'
import { DESKTOP } from '@/modules/bridge.js'

/** @type {import('simple-store-svelte').Writable<{ mode: string, modes: string[], overridden: boolean, effective?: string, failedStarts?: number }>} */
export const graphics = writable({ mode: 'auto', modes: [], overridden: false })

/** What each mode means, for the settings screen. In the order the host offers them. */
export const graphicsModes = {
  auto: 'Automatic — the GPU path, stepping down only if a launch cannot draw',
  gpu: 'GPU — accelerated compositing as WebKit ships it',
  'nvidia-sync': "NVIDIA without explicit sync — accelerated, minus the synchronisation NVIDIA's driver and WebKit disagree about",
  'no-gbm': 'GPU without GBM — accelerated, skipping the buffer allocation some drivers reject',
  shm: 'Shared memory — frames go through the CPU; slower, works nearly everywhere',
  safe: 'Safe — no DMABUF renderer and no compositing, slowest and most compatible',
  // stored preferences written by earlier versions, so an old value still reads
  'gpu-no-gbm': 'GPU without GBM — accelerated, skipping the buffer allocation some drivers reject',
  'no-dmabuf': 'Shared memory — frames go through the CPU; slower, works nearly everywhere'
}

/** The modes that composite on the GPU, for wording that depends on it. */
const accelerated = new Set(['gpu', 'nvidia-sync', 'no-gbm', 'gpu-no-gbm'])

/**
 * What the host has settled on, or null when nothing needs saying. A fallback is invisible
 * otherwise, and it costs real smoothness: every composited frame goes through the CPU, so
 * the app feels slow for a reason the user cannot see.
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
  // auto is on a lower rung because a launch here proved it needed one. Which rung matters:
  // the accelerated ones cost nothing worth mentioning, the others cost every frame
  return accelerated.has(effective)
    ? `Automatic is using ${name}: the plain GPU path could not draw on this machine, so it is working around the driver rather than giving up on it. Still accelerated.`
    : `Automatic is using ${name}: accelerated compositing could not draw a window on this machine, and a black window is not worth the frame rate. It tries the GPU again on its own after a driver, kernel or WebKit update.`
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
