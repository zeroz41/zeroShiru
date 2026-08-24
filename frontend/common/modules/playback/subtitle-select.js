// Which subtitle track plays, decided in exactly one place.
//
// Three selectors used to compete for that decision: the Subtitles class auto-picked by
// the settings language when tracks arrived, PlayerPage re-applied the remembered track
// from inside the change callback (the ring that once recursed to a stack overflow — see
// git 8d6328de^..d3083cb3), and the dropdown wrote its own display label into the cache
// for the restore to fuzzy-match later with levenshtein distance. The remembered value
// was literally "ENG (Full Subtitles)" matched against "eng - Full Subtitles" and only
// worked because the edit distance happened to fit the tolerance.
//
// Now: one pure chooser, called with everything it needs, returning a ranked choice.
// Selection is remembered as data — { language, name } — not as a rendered label.

/** How strongly a choice binds, so a later-arriving track (an external .ass file lands
 * seconds after the embedded ones) only takes over when it is a strictly better match. */
export const CHOICE = { none: 0, fallback: 1, english: 2, language: 3, remembered: 4 }

/** The value persisted when the user picks a track: enough to find the same subtitles
 * in the next episode's file, which is a different file with the same track layout. */
export function trackChoice (track) {
  return { language: track?.language ?? '', name: track?.name ?? '' }
}

/** The label a track shows in the picker. Kept next to the chooser so legacy remembered
 * labels (the picker used to persist this string) keep matching what they were made from. */
export function trackLabel (track) {
  const language = (track?.language || track?.type || '?').toUpperCase()
  const name = track?.name ? ` (${track.name})` : ''
  return language + name
}

/** Case- and punctuation-blind form, so "ENG (Full Subtitles)", "eng - Full Subtitles"
 * and { language: 'eng', name: 'Full Subtitles' } all collapse to the same key. */
const normalize = value => String(value ?? '').toLowerCase().replace(/[^a-z0-9]+/g, '')

/** Whether a persisted choice — structured or a legacy label string — means this track. */
export function choiceMatches (remembered, track) {
  if (!remembered || remembered === 'OFF') return false
  if (typeof remembered === 'object') {
    return normalize(remembered.language) === normalize(track.language) &&
      normalize(remembered.name) === normalize(track.name)
  }
  const key = normalize(remembered)
  return key === normalize(trackLabel(track)) ||
    key === normalize(`${track.language ?? ''} ${track.name ?? ''}`) ||
    (!track.name && key === normalize(track.language))
}

/**
 * The track that should be playing, or null to leave subtitles alone.
 *
 * @param {Array<{ number: number, language?: string, name?: string, type?: string,
 *   default?: boolean, forced?: boolean }>} tracks - Every known track, embedded and external.
 * @param {{ remembered?: any, language?: string }} wants - The user's remembered choice
 *   for this show ('OFF', a { language, name } object, or a legacy label string) and
 *   their preferred subtitle language from settings.
 * @returns {{ number: number, score: number } | null} score is a CHOICE rank; -1 means
 *   subtitles off.
 */
export function chooseSubtitleTrack (tracks, { remembered, language } = {}) {
  const known = (tracks ?? []).filter(Boolean)
  if (remembered === 'OFF') return { number: -1, score: CHOICE.remembered }
  if (!known.length) return null

  if (remembered) {
    const match = best(known.filter(track => choiceMatches(remembered, track)))
    if (match) return { number: match.number, score: CHOICE.remembered }
    // a structured choice can outlive a rename: same language, different name
    if (typeof remembered === 'object' && remembered.language) {
      const sameLanguage = best(known.filter(track => normalize(track.language) === normalize(remembered.language)))
      if (sameLanguage) return { number: sameLanguage.number, score: CHOICE.remembered }
    }
  }

  // no remembered choice: the settings language decides, and no language means the user
  // wants no subtitles appearing on their own
  if (!language) return null
  if (known.length === 1) return { number: known[0].number, score: CHOICE.english }

  const wanted = best(known.filter(track =>
    normalize(track.language) === normalize(language) ||
    (track.name ?? '').toLowerCase().includes(language.toLowerCase())
  ))
  if (wanted) return { number: wanted.number, score: CHOICE.language }

  const english = best(known.filter(track => ['eng', 'en'].includes((track.language ?? 'eng').toLowerCase())))
  if (english) return { number: english.number, score: CHOICE.english }

  return { number: known[0].number, score: CHOICE.fallback }
}

/** Of several matching tracks, the one to play: full dialogue over a forced signs
 * track, the muxer's default over the rest, file order last. */
function best (candidates) {
  if (!candidates?.length) return null
  return [...candidates].sort((a, b) =>
    (Number(a.forced ?? false) - Number(b.forced ?? false)) ||
    (Number(b.default ?? false) - Number(a.default ?? false))
  )[0]
}
