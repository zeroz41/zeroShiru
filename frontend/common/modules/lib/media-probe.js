// Whether this platform can play media at all, asked shortly after boot with a
// one-tick silent clip, so a dead media stack says so in the log instead of
// freezing the first video someone tries to watch.
//
// Why this exists: the webview plays everything through the platform's GStreamer,
// and a build where the plugins cannot be found does not degrade — WebKit's element
// lookup comes up empty, a signal is connected on a null sink, and the web process
// goes down with the player. That has now shipped twice, both times invisible until
// a human pressed play, and the only evidence was two lines on a stderr nobody was
// watching. The probe plays a clip nothing can be wrong with; if even that fails,
// the failure is the platform's, and it lands in the log the user can export.
//
// Pure pieces first, so the rules are testable without a DOM or an <audio> element.

/** How long after boot the question is asked: after first paint, before first play. */
export const PROBE_DELAY = 3_000

/** How long a trivial clip gets before silence itself is the answer. */
export const PROBE_TIMEOUT = 15_000

/**
 * The smallest thing that is unambiguously audio: a PCM WAV of silence, built here
 * rather than pasted as base64 so it can be read and trusted. Anything that can
 * play sound at all can play this; a stack that cannot has nothing, not no codec.
 * @param {number} [samples]
 * @returns {string} A data: URI.
 */
export function silentWavUri (samples = 8) {
  const bytes = new Uint8Array(44 + samples)
  const view = new DataView(bytes.buffer)
  const ascii = (offset, text) => { for (let i = 0; i < text.length; i++) bytes[offset + i] = text.charCodeAt(i) }
  ascii(0, 'RIFF')
  view.setUint32(4, 36 + samples, true)
  ascii(8, 'WAVE')
  ascii(12, 'fmt ')
  view.setUint32(16, 16, true) // PCM header size
  view.setUint16(20, 1, true) // PCM
  view.setUint16(22, 1, true) // mono
  view.setUint32(24, 8000, true) // sample rate
  view.setUint32(28, 8000, true) // byte rate
  view.setUint16(32, 1, true) // block align
  view.setUint16(34, 8, true) // bits per sample
  ascii(36, 'data')
  view.setUint32(40, samples, true)
  bytes.fill(0x80, 44) // 8-bit silence sits at the midpoint
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return `data:audio/wav;base64,${btoa(binary)}`
}

/**
 * A MediaError as a sentence. The codes are the four the platform defines; a stack
 * with no plugins reports the silent clip as unsupported or undecodable, which is
 * why those two spell out what they almost always mean here.
 * @param {{ code?: number, message?: string } | null | undefined} error
 */
export function describeMediaError (error) {
  const meaning = {
    1: 'playback was aborted',
    2: 'a network error, for a clip that never touches the network',
    3: 'the platform could not decode PCM silence',
    4: 'the platform reports plain WAV as unsupported'
  }[error?.code] ?? 'the element errored without saying why'
  return error?.message ? `${meaning}: ${error.message}` : meaning
}

/**
 * Plays the silent clip and reports whether the platform managed it.
 * @param {Object} [options]
 * @param {() => any} [options.create] - Makes the audio element; defaults to `new Audio()`.
 * @param {number} [options.timeout]
 * @param {(callback: () => void, delay: number) => any} [options.schedule] - Defaults to setTimeout.
 * @returns {Promise<{ ok: boolean, reason?: string }>}
 */
export function probeMediaPipeline ({ create = () => new Audio(), timeout = PROBE_TIMEOUT, schedule = setTimeout } = {}) {
  return new Promise(resolve => {
    let audio
    try {
      audio = create()
    } catch (error) {
      return resolve({ ok: false, reason: `no audio element on this platform: ${error?.message ?? error}` })
    }
    if (!audio) return resolve({ ok: false, reason: 'no audio element on this platform' })

    let done = false
    const settle = result => {
      if (done) return
      done = true
      // let the element go: no src, no pending load, nothing for a sink to hold
      try {
        audio.removeAttribute?.('src')
        audio.load?.()
      } catch {}
      resolve(result)
    }

    audio.addEventListener?.('canplaythrough', () => settle({ ok: true }), { once: true })
    audio.addEventListener?.('error', () => settle({ ok: false, reason: describeMediaError(audio.error) }), { once: true })
    const timer = schedule(() => settle({ ok: false, reason: `no answer after ${timeout}ms` }), timeout)
    timer?.unref?.()

    try {
      audio.muted = true
      audio.preload = 'auto'
      audio.src = silentWavUri()
      audio.load?.()
    } catch (error) {
      settle({ ok: false, reason: `the element refused a source: ${error?.message ?? error}` })
    }
  })
}

/**
 * Schedules the probe and reports its verdict where diagnostics already go: the
 * console, which the log forwarder carries to the host. Failure is an error and
 * always crosses; success is only worth a line when someone turned debugging on.
 * @param {Object} [options]
 * @param {any} [options.console] - Defaults to the global console.
 * @param {() => any} [options.create]
 * @param {number} [options.timeout]
 * @param {number} [options.delay]
 * @param {(callback: () => void, delay: number) => any} [options.schedule]
 */
export function attachMediaProbe ({ console: target = globalThis.console, create, timeout, delay = PROBE_DELAY, schedule = setTimeout } = {}) {
  const timer = schedule(async () => {
    const { ok, reason } = await probeMediaPipeline({ create, timeout, schedule })
    if (ok) return target.debug?.('media pipeline self-test passed')
    target.error?.(
      `media pipeline self-test failed (${reason}). ` +
      'The platform media stack (GStreamer) cannot play a trivial clip, so no video will play either. ' +
      'In the AppImage this means the GStreamer plugins are not visible to the app — see scripts/bundle.sh and scripts/verify-appimage.sh.'
    )
  }, delay)
  timer?.unref?.()
}
