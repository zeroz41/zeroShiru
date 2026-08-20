// How an extension's HTTP requests actually get made.
//
// Extensions are content sources: they scrape sites and call APIs that were never written with
// this app in mind, so most of them send no CORS headers. Under Electron that did not matter,
// because it ran with web security switched off and the renderer could read any response. A
// real webview cannot: the request goes out and the answer is withheld, which reads to an
// extension as "the source is unreachable" — nyaa.si, to pick the obvious one.
//
// So where the host can make the request itself, it does. A native HTTP client is not a browser
// and has nothing to enforce; what it must not become is a way for page content to reach the
// local network, which is why the host checks every destination and every redirect hop, and why
// the private-address check below still runs before we ever ask.
//
// The shape the caller gets back is the same either way, so an extension cannot tell which
// path it went down — and a host with no native client (a TV bootstrap, a browser) simply keeps
// using fetch and works exactly as well as CORS allows.

/** The subset of `Response` extensions read. Built from whatever the host handed back. */
function responseFrom (result) {
  const headers = new Map(Object.entries(result.headers || {}).map(([name, value]) => [name.toLowerCase(), value]))
  return {
    ok: result.ok,
    status: result.status,
    statusText: '',
    url: result.url,
    redirected: result.url !== result.requestUrl,
    headers: {
      get: (name) => headers.get(String(name).toLowerCase()) ?? null,
      has: (name) => headers.has(String(name).toLowerCase()),
      entries: () => headers.entries(),
      forEach: (fn) => headers.forEach((value, name) => fn(value, name))
    },
    text: async () => result.body,
    json: async () => JSON.parse(result.body),
    arrayBuffer: async () => new TextEncoder().encode(result.body).buffer
  }
}

/**
 * Makes one request the way this host can.
 *
 * @param {string} url
 * @param {RequestInit} [options]
 * @param {object} deps
 * @param {(request: object) => Promise<object>} [deps.hostRequest] - The host's native client, when it has one.
 * @param {(url: string, options?: object) => Promise<Response>} deps.fetch - The webview's own fetch.
 * @param {(url: string) => boolean} [deps.blocked] - Refuses a destination before it is asked for.
 * @returns {Promise<object>} A Response, or something shaped enough like one.
 */
export async function requestVia (url, options = {}, { hostRequest, fetch: webFetch, blocked } = {}) {
  if (blocked?.(url)) throw new Error('Access denied: requests to private or local network addresses are not permitted.')
  if (!hostRequest) return webFetch(url, options)

  const result = await hostRequest({
    url,
    method: normalizeMethod(options.method),
    headers: headersOf(options.headers),
    body: typeof options.body === 'string' ? options.body : undefined
  })
  if (blocked?.(result.url)) throw new Error('Access denied: request was redirected to a private or local network address.')
  return responseFrom({ ...result, requestUrl: url })
}

/** Methods a source may ask for. Anything else is a mistake, and GET is the safe reading of one. */
export function normalizeMethod (method) {
  const wanted = String(method || 'GET').toUpperCase()
  return ['GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD'].includes(wanted) ? wanted : 'GET'
}

/** Headers as a plain object, from any of the shapes fetch accepts. */
export function headersOf (headers) {
  if (!headers) return {}
  if (typeof headers.forEach === 'function' && !Array.isArray(headers)) {
    const plain = {}
    headers.forEach((value, name) => { plain[name] = value })
    return plain
  }
  if (Array.isArray(headers)) return Object.fromEntries(headers)
  return { ...headers }
}
