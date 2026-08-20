/**
 * Whether a torrent-session notification should reach the user as a toast.
 *
 * Two rules, both learned the hard way:
 * - While debrid is the transport — a debrid stream owns playback, or the mode is
 *   debrid-only — the torrent lane's chatter is somebody else's weather. The session
 *   still runs (staging, seeding, the startup restore), and its failures still land
 *   in the debug log, but a user who is streaming from their debrid service must
 *   never be shown a torrent error for a lane they are not using.
 * - The user's toast preference applies to every level. Info used to bypass it
 *   entirely, which meant "Errors only" still showed restart reminders.
 *
 * @param {string} type 'info' | 'warn' | 'error'
 * @param {{ toasts: string, debridActive: boolean }} context
 * @returns {boolean}
 */
export function torrentToast (type, { toasts, debridActive }) {
  if (debridActive) return false
  if (toasts.includes('All')) return true
  if (type === 'error') return toasts.includes('Errors') || toasts.includes('Warnings')
  if (type === 'warn') return toasts.includes('Warnings')
  return false
}
