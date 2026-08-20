/**
 * The absolute URL of an asset shipped with the app.
 *
 * A relative path is only meaningful next to the thing that resolves it, and the
 * subtitle renderer resolves its fonts inside a web worker: the worker lives under
 * `assets/`, so `./Roboto.ttf` asked the app for `assets/Roboto.ttf`, which does not
 * exist. The fallback font never loaded, and any subtitle whose font is not embedded
 * in the file had nothing to render with. The page's own base is the only base that
 * means what the path says.
 *
 * @param {string} path A path relative to the app root, or an absolute URL.
 * @param {string} [base] The document base; passed in for tests.
 * @returns {string} An absolute URL, or the path unchanged if it cannot be resolved.
 */
export function assetUrl (path, base = typeof document !== 'undefined' ? document.baseURI : undefined) {
  if (typeof path !== 'string' || !path) return path
  try {
    return new URL(path, base).href
  } catch {
    return path // no base to resolve against, which is the caller's own problem
  }
}
