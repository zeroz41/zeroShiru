/**
 * WebKitGTK's network-backed media source never prerolls a large Matroska file:
 * the same URL decodes through native GStreamer, while the HTML media element
 * remains at HAVE_NOTHING.  Keep this decision small and explicit so MP4 and
 * other containers still use the embedded player.
 */
export function requiresNativePlayback (file, platform) {
  if (platform !== 'linux' || !file) return false
  if (/matroska/i.test(String(file.type || file.mime || ''))) return true
  return [file.name, file.path, file.url].some(value => /\.mkv(?:$|[?#])/i.test(String(value || '')))
}

