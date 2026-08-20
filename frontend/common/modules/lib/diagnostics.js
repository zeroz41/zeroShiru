// What the page says about itself, sent somewhere a user can actually read it.
//
// Every hunt through this app's webview has cost hours for the same reason: the page's
// own errors go to a console that is never open. A missing `navigator.vibrate` broke
// every click in the app and said so only there; a debrid check that fails says so only
// there. The host writes a log the user can export, so the page's diagnostics belong in
// it — errors and warnings always, the rest only when debug logging is on, since a busy
// app writes thousands of lines a minute and a log nobody can read helps nobody.
//
// Pure rules first, so they are testable without a console, a host or a DOM.

/** Console methods that are worth a log line, and the level each maps to. */
export const CONSOLE_LEVELS = Object.freeze({
  error: 'error',
  warn: 'warn',
  info: 'info',
  log: 'debug',
  debug: 'debug'
})

/** Levels that go to the host whether or not debug logging is on. */
const ALWAYS = new Set(['error', 'warn'])

/** How long answers are collected before one call carries them all. */
export const FLUSH_DELAY = 300

/** The most lines one call carries, so a burst cannot build an unbounded payload. */
export const MAX_BATCH = 100

/** The most a single line may be, matching the host's own cap. */
export const MAX_MESSAGE = 2_000

/**
 * Whether a line at this level is worth sending. Debug chatter is only worth the
 * crossing when someone is reading it; a failure always is.
 * @param {string} level
 * @param {boolean} verbose - Whether the user turned debug logging on.
 */
export function forwards (level, verbose) {
  return ALWAYS.has(level) || Boolean(verbose)
}

/**
 * One console argument as a string. Objects are worth reading, cycles and getters that
 * throw are not worth crashing over, and a value that cannot be described at all still
 * gets a line rather than taking the log entry down with it.
 * @param {any} value
 */
export function describe (value) {
  if (typeof value === 'string') return value
  if (value instanceof Error) return value.stack || `${value.name}: ${value.message}`
  if (value === null || value === undefined || typeof value !== 'object') return String(value)
  try {
    const seen = new WeakSet()
    return JSON.stringify(value, (key, entry) => {
      if (key && secretRx.test(key)) return REDACTED
      if (entry && typeof entry === 'object') {
        if (seen.has(entry)) return '[circular]'
        seen.add(entry)
        // a map of keys by service id: the names are ids, the values are still keys
        if (secretRx.test(key || '')) return REDACTED
      }
      return entry instanceof Error ? (entry.stack || String(entry)) : entry
    }) ?? String(value)
  } catch {
    return Object.prototype.toString.call(value)
  }
}

/** Terminal colouring, which some loggers emit and no text log wants. */
const ansiRx = /\u001b\[[0-9;]*m/g

/**
 * Names whose values are secrets. The log is a file the user is invited to export and
 * send to someone, and the settings object alone carries every debrid API key they have.
 */
const secretRx = /(api[-_]?key|apikey|token|secret|password|authorization|bearer)/i

/** What a redacted value looks like, short enough to read past. */
const REDACTED = '[redacted]'

/**
 * Hides secrets in a line, whatever shape they arrived in: a JSON field, a query
 * parameter, an Authorization header printed as text.
 * @param {string} line
 */
export function redact (line) {
  return line
    // a whole map of them, which is how the settings object carries a key per service:
    // "debridApiKeys":{"torbox":"…"}. Loggers that format objects into a string before
    // handing them over — which the `debug` package does — only ever produce this shape
    .replace(/(["']?[\w-]*(?:api[-_]?keys?|apikeys?|tokens?|secrets?|passwords?)[\w-]*["']?\s*[:=]\s*)\{[^{}]*\}/gi, `$1{${REDACTED}}`)
    // "apiKey":"…" and 'token': …
    .replace(/(["']?[\w-]*(?:api[-_]?key|apikey|token|secret|password|authorization)[\w-]*["']?\s*[:=]\s*)(["'])(?:\\.|(?!\2)[^\\])*\2/gi, `$1$2${REDACTED}$2`)
    // apiKey=… in a URL or a log line, up to the next separator
    .replace(/([\w-]*(?:api[-_]?key|apikey|token|secret|password)[\w-]*=)[^&\s"']+/gi, `$1${REDACTED}`)
    // Authorization: Bearer …
    .replace(/(bearer\s+)[\w.\-~+/]+=*/gi, `$1${REDACTED}`)
}

/**
 * Console arguments as one line: colouring stripped, secrets hidden, and cut to length
 * here as well as in the host, since a line the host would only truncate is not worth
 * sending whole.
 * @param {any[]} args
 */
export function format (args) {
  const line = redact(args.map(describe).join(' ').replace(ansiRx, ''))
  return line.length > MAX_MESSAGE ? `${line.slice(0, MAX_MESSAGE)}… [${line.length - MAX_MESSAGE} more characters]` : line
}

/**
 * How an uncaught error reads in the log. Both browser shapes land here: `error` events
 * carry a filename and position, rejections carry only a reason.
 * @param {any} error - The thrown value or rejection reason.
 * @param {{ filename?: string, lineno?: number, colno?: number }} [where]
 */
export function describeFailure (error, where = {}) {
  const at = where.filename ? ` at ${where.filename}:${where.lineno ?? 0}:${where.colno ?? 0}` : ''
  return `${describe(error)}${at}`
}

/**
 * Collects lines and hands them over in batches. An app logs in bursts — one render,
 * one failed request, one sweep answering — and a call per line would cost more than
 * the logging is worth.
 *
 * @param {Object} options
 * @param {(entries: { level: string, scope: string, message: string }[]) => any} options.send - The host call.
 * @param {() => boolean} [options.verbose] - Whether debug logging is on, asked per line so turning it on takes effect at once.
 * @param {(callback: () => void, delay: number) => any} [options.schedule] - Defaults to setTimeout.
 */
export function createForwarder ({ send, verbose = () => false, schedule = setTimeout }) {
  /** @type {{ level: string, scope: string, message: string }[]} */
  let queued = []
  let waiting = false

  function flush () {
    waiting = false
    if (!queued.length) return
    const entries = queued
    queued = []
    try {
      const sent = send(entries)
      // a host that cannot log must not take the page down with it
      if (sent && typeof sent.catch === 'function') sent.catch(() => {})
    } catch {}
  }

  return {
    /**
     * @param {string} level
     * @param {string} scope - Where the line came from: a console method, a `debug` namespace, an event.
     * @param {string} message
     */
    record (level, scope, message) {
      if (!forwards(level, verbose())) return
      queued.push({ level, scope, message })
      // a burst goes now rather than growing: the interesting lines are usually the
      // ones right before something stops responding
      if (queued.length >= MAX_BATCH) return flush()
      if (waiting) return
      waiting = true
      const timer = schedule(flush, FLUSH_DELAY)
      timer?.unref?.()
    },
    flush,
    get pending () { return queued.length }
  }
}

/**
 * A `debug` namespace line as one string. The package formats for a devtools console —
 * `%c` directives and a CSS argument per directive — which reads as noise in a text log.
 * @param {any[]} args
 */
export function describeDebug (args) {
  if (typeof args[0] !== 'string' || !args[0].includes('%c')) return format(args)
  const rest = args.slice(1).filter(arg => !(typeof arg === 'string' && (arg === '' || arg.trimStart().startsWith('color'))))
  return format([args[0].replaceAll('%c', ''), ...rest])
}

/**
 * Points the page's diagnostics at the host log: every console method, uncaught errors,
 * and unhandled rejections. Returns a function that puts everything back, which is what
 * the tests use and what a host without a log never needs.
 *
 * @param {Object} options
 * @param {(entries: { level: string, scope: string, message: string }[]) => any} options.send - The host call.
 * @param {() => boolean} [options.verbose]
 * @param {any} [options.console] - Defaults to the global console.
 * @param {any} [options.target] - Where error events are listened for, defaulting to window.
 * @param {any} [options.debug] - The `debug` package, whose output the console hook cannot see.
 * @param {(callback: () => void, delay: number) => any} [options.schedule]
 */
export function attachDiagnostics ({ send, verbose, console: target = console, target: events = globalThis, debug: debugPackage, schedule } = {}) {
  if (typeof send !== 'function') return () => {}
  const forwarder = createForwarder({ send, verbose, schedule })

  // `debug` reads console.debug once, at its own import, and calls that reference forever:
  // hooking the console later never sees a namespace line, which is most of what the app
  // says about itself. It writes through one seam, so that is where to stand.
  const debugLog = debugPackage?.log
  if (debugPackage) {
    debugPackage.log = (...args) => {
      try {
        forwarder.record('debug', 'debug', describeDebug(args))
      } catch {}
      return debugLog?.apply(debugPackage, args)
    }
  }

  /** @type {[string, any][]} */
  const replaced = []
  for (const [method, level] of Object.entries(CONSOLE_LEVELS)) {
    const original = target?.[method]
    if (typeof original !== 'function') continue
    replaced.push([method, original])
    target[method] = (...args) => {
      try {
        forwarder.record(level, `console.${method}`, format(args))
      } catch {}
      return original.apply(target, args)
    }
  }

  const onError = (event) => forwarder.record('error', 'uncaught', describeFailure(event?.error ?? event?.message, event))
  const onRejection = (event) => forwarder.record('error', 'unhandled rejection', describeFailure(event?.reason))
  events?.addEventListener?.('error', onError)
  events?.addEventListener?.('unhandledrejection', onRejection)

  return () => {
    if (debugPackage) debugPackage.log = debugLog
    for (const [method, original] of replaced) target[method] = original
    events?.removeEventListener?.('error', onError)
    events?.removeEventListener?.('unhandledrejection', onRejection)
    forwarder.flush()
  }
}

/**
 * Whether the user has debug logging on. `debug` reads the same key, so one switch
 * turns on both the console namespaces and what reaches the log.
 * @param {any} [storage] - Defaults to localStorage.
 */
export function debugLogging (storage = globalThis.localStorage) {
  try {
    return Boolean(storage?.getItem?.('debug'))
  } catch {
    return false
  }
}
