// What the player asks before an episode starts, and what it does when nobody answers.
//
// The bug this answers: an episode that loaded and then never played. Whether an episode is
// filler or a recap comes from Jikan, and the player awaited that answer before calling
// play(). Jikan is rate limited, often slow, and throws outright when it is unreachable —
// and that throw went straight through the autoplay path, so the video sat ready, paused,
// under a spinner, forever, because nobody could say what kind of episode it was.
//
// Two rules come out of that. An answer nobody gave is not a reason to prompt: an unknown
// episode is a normal episode. And the answer is worth a short wait, not an unbounded one —
// playback starts on time, and an answer that arrives late and does matter stops it and asks
// then, which is the same question a moment later instead of a video that never began.

/** How long the start of playback waits on a third party to say what kind of episode this is. */
export const EPISODE_PROMPT_DEADLINE = 2_000

/**
 * What to say about an episode, from whatever the lookup came back with.
 *
 * @param {any} [episode] The lookup's answer: an episode, an empty list when the show is
 *   known but the episode is not, or nothing at all when the lookup failed.
 * @returns {{ filler: string | null, recap: string | null, prompt: boolean }}
 */
export function episodePrompt (episode) {
  const filler = episode?.filler ? 'Filler' : null
  const recap = episode?.recap ? 'Recap' : null
  return { filler, recap, prompt: Boolean(filler || recap) }
}
