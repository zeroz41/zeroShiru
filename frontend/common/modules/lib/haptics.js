// The little buzz a tap gives back, where the platform has one.
//
// It exists as its own module because of what happened when it did not. The click action
// called `navigator.vibrate(15)` before running the handler it was decorating, and WebKitGTK
// — what Tauri renders with on Linux — has no Vibration API at all. Every click in the app
// threw before reaching its callback, so nothing was clickable: no navigation, no buttons,
// no cards. A decoration silently took the whole app down with it.
//
// So: never let this throw, whatever the platform thinks of it. Nothing here is worth an
// interaction.

/**
 * A short haptic tap, if this platform does haptics.
 * @param {number} [duration] - Milliseconds.
 * @returns {boolean} Whether the platform actually buzzed.
 */
export function tap (duration = 15) {
  try {
    // absent on desktop WebKit, present but refused inside cross-origin frames or without a
    // user gesture on some engines — either way the caller's business is elsewhere
    return navigator?.vibrate?.(duration) ?? false
  } catch {
    return false
  }
}
