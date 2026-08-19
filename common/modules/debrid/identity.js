// How a playing debrid file is identified, free of UI imports so it runs under plain Node for
// tests. The fileHash here MUST stay byte-identical to the torrent client's
// makeHash(`${infoHash}:${name}:${size}`) — it is the key watch progress and resume positions
// are stored under, and debrid and torrent playback of the same release share it.

/**
 * SHA-1 of a string, hex encoded. The WebCrypto twin of the client's node `createHash('sha1')`.
 * @param {string} data
 * @returns {Promise<string>}
 */
export async function sha1hex (data) {
  const buffer = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(data))
  return Array.from(new Uint8Array(buffer)).map(byte => byte.toString(16).padStart(2, '0')).join('')
}

/**
 * Shapes one resolved debrid file like the torrent client's file objects, shared watch key
 * included.
 * @param {{ hash: string, name: string }} resolved - The resolved torrent (lowercase hash).
 * @param {import('./service.js').DebridFile} file
 */
export async function toPlayerFile (resolved, file) {
  return {
    infoHash: resolved.hash,
    fileHash: await sha1hex(`${resolved.hash}:${file.name}:${file.size}`), // same key the torrent client uses, so watch progress is shared
    torrent_name: resolved.name,
    name: file.name,
    type: file.type,
    size: file.size,
    path: file.path,
    url: file.url,
    debrid: true
  }
}
