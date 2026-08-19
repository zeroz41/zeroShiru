// Reading a connectivity probe. Pure: no fetch, no stores, no host — the rules only,
// so they can be tested without a network and shared by every host.
//
// The vocabulary matches the Rust core's (crates/networking/src/reachability.rs), which
// is what a native host answers with:
//
//   online   an endpoint answered as promised; there is a connection
//   portal   something answered, but not what was asked for (captive portal, proxy)
//   offline  the connection failed outright; a real answer
//   unknown  nothing answered in time, or the endpoint itself is broken; NOT an answer
//
// A webview can rarely reach `portal`: a connectivity endpoint has no CORS headers, so
// the ping must go out `no-cors` and comes back opaque — status 0, body sealed. That it
// arrived is then the whole measurement. Hosts with a native HTTP stack ask through the
// core instead and get the real status, which is why they can spot a portal at all.

/** What one webview response says about the connection. */
export function readResponse (response) {
  if (!response) return 'unknown'
  // opaque: the request completed but the answer is sealed. Completing is the point.
  if (response.type === 'opaque') return 'online'
  if (response.status === 204 || response.ok) return 'online'
  // the endpoint is unwell, which is news about the endpoint and not about us
  if (response.status >= 400) return 'unknown'
  // a success that is not the promised 204: somebody answered on its behalf
  return 'portal'
}

/** What a failed webview request says. Our own timeout aborts, so an abort is not a verdict. */
export function readError (error) {
  const name = error?.name
  if (name === 'AbortError' || name === 'TimeoutError') return 'unknown'
  return 'offline'
}

/**
 * Whether a probe result should be read as connected, given what was already believed.
 *
 * `unknown` is the load-bearing case: a slow link answers nothing inside a short budget,
 * and reporting that as an outage is how an app on bad internet decides it is offline
 * while it is not. No answer means keep the state we had.
 */
export function isConnected (result, wasOffline = false) {
  if (result === 'online') return true
  if (result === 'unknown') return !wasOffline
  return false
}
