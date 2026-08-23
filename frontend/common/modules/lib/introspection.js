// Pure rules for the live diagnostics panel: how host health is worded and judged.
// Kept out of the component so the judgments are testable — a wrong "healthy" badge
// on a wedged service would defeat the whole point of the surface.

/** @param {number} [ms] */
export function prettyDuration (ms) {
  if (!Number.isFinite(ms) || ms < 0) return '—'
  const seconds = Math.floor(ms / 1000)
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ${seconds % 60}s`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

/**
 * One verdict per debrid service, worst condition first: the badge must name the
 * thing that is currently costing the user, not the mildest true fact.
 * @param {{ quiet?: boolean, paused_for_ms?: number, sweeping?: boolean, orphaned_removals?: number, requests_waiting?: number, latency_ms?: number }} [health]
 * @returns {{ label: string, tone: 'danger' | 'warning' | 'ok' }}
 */
export function serviceVerdict (health = {}) {
  if (health.quiet) return { label: 'not answering', tone: 'danger' }
  if (health.paused_for_ms > 0) return { label: `rate limited ${prettyDuration(health.paused_for_ms)}`, tone: 'warning' }
  if (health.orphaned_removals > 0) return { label: `owes ${health.orphaned_removals} cleanup${health.orphaned_removals === 1 ? '' : 's'}`, tone: 'warning' }
  if (health.sweeping) return { label: 'sweeping', tone: 'ok' }
  if (health.requests_waiting > 0) return { label: `${health.requests_waiting} queued`, tone: 'ok' }
  return { label: 'healthy', tone: 'ok' }
}

/**
 * The host log-verbosity presets the settings screen offers. `filter` is what
 * crosses to the host; empty returns to the default.
 */
export const LOG_PRESETS = [
  { label: 'Default', filter: '' },
  { label: 'Verbose', filter: 'debug,librqbit=info,renderer=debug' },
  { label: 'Debrid Trace', filter: 'info,debrid=trace,renderer=debug' },
  { label: 'Torrent Debug', filter: 'info,shiru_torrent=debug,librqbit=debug,renderer=debug' },
  { label: 'Everything', filter: 'trace' }
]

/**
 * How full the renderer's log-line allowance is, as words when it matters.
 * @param {{ renderer_lines?: number, renderer_line_cap?: number }} [log]
 * @returns {string | null} A warning line, or null while there is nothing to say.
 */
export function lineAllowanceNotice (log = {}) {
  const used = log.renderer_lines ?? 0
  const cap = log.renderer_line_cap ?? 0
  if (!cap || used < cap * 0.8) return null
  if (used >= cap) return 'the page hit its log-line allowance; reset the log to keep capturing'
  return `the page has used ${Math.round((used / cap) * 100)}% of its log-line allowance`
}
