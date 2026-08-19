// A stream link for the live playback tests, and nothing more.
//
// The debrid providers themselves live in Rust now (crates/debrid, with live coverage in
// crates/debrid/tests/live.rs). The renderer-side player pieces — DebridMetadata, subtitle
// and font extraction — are still JS, and testing them against a real CDN needs a real
// HTTPS link. This is the smallest thing that produces one: no rate limiting, no
// availability memory, no error taxonomy. It is test scaffolding, not a provider.
const API = 'https://api.torbox.app/v1/api'

const key = () => process.env.TORBOX_API_KEY

/** @param {string} path @param {RequestInit} [init] */
async function api (path, init) {
  const response = await fetch(`${API}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${key()}`, ...init?.headers }
  })
  const body = await response.json().catch(() => null)
  if (!response.ok || body?.success === false) throw new Error(`TorBox ${path}: ${body?.detail || body?.error || response.status}`)
  return body?.data
}

/** The account's torrents as id -> lowercase info hash, for leave-no-trace bookkeeping. */
export async function accountTorrents () {
  const data = await api('/torrents/mylist?bypass_cache=true&limit=1000')
  return new Map((data || []).map(torrent => [torrent.id, String(torrent.hash).toLowerCase()]))
}

/** @param {number | string} id */
export async function deleteTorrent (id) {
  return api('/torrents/controltorrent', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ torrent_id: id, operation: 'delete' })
  }).catch(() => {})
}

/**
 * Resolves a cached hash to stream links, the way the app's Rust core does.
 * @param {string} hash - Lowercase info hash, already cached on the account.
 * @param {{ filter?: (name: string) => boolean, maxFiles?: number }} [opts]
 * @returns {Promise<{ hash: string, name: string, files: { name: string, path: string, size: number, url: string }[] }>}
 */
export async function resolveTorBox (hash, { filter = () => true, maxFiles = 12 } = {}) {
  const listed = (await api(`/torrents/mylist?bypass_cache=true&limit=1000`) || [])
    .find(torrent => String(torrent.hash).toLowerCase() === hash.toLowerCase())
  const torrent = listed || await addMagnet(hash)
  const files = (torrent.files || [])
    .map(file => ({
      id: file.id,
      name: file.short_name || String(file.name).split('/').pop(),
      path: '/' + String(file.name).replace(/^\/+/, ''),
      size: file.size
    }))
    .filter(file => filter(file.name))
    .slice(0, maxFiles)
  if (!files.length) throw new Error(`nothing playable in ${torrent.name}`)
  const linked = await Promise.all(files.map(async file => ({
    ...file,
    url: await api(`/torrents/requestdl?torrent_id=${torrent.id}&file_id=${file.id}&redirect=false&token=${encodeURIComponent(key())}`)
  })))
  return { hash: String(torrent.hash).toLowerCase(), name: torrent.name, files: linked }
}

/** Adds a magnet and waits for the file list to appear. */
async function addMagnet (hash) {
  const form = new FormData()
  form.append('magnet', `magnet:?xt=urn:btih:${hash}`)
  form.append('seed', '3') // never seed: these tests only stream
  const added = await api('/torrents/createtorrent', { method: 'POST', body: form })
  const id = added?.torrent_id ?? added?.id
  for (let attempt = 0; attempt < 20; attempt++) {
    const listed = (await api(`/torrents/mylist?bypass_cache=true&id=${id}`)) || null
    const torrent = Array.isArray(listed) ? listed[0] : listed
    if (torrent?.files?.length) return torrent
    await new Promise(resolve => setTimeout(resolve, 1_000))
  }
  throw new Error(`TorBox never listed the files of ${hash}`)
}
