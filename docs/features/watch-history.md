# Watch history and tracking

Zero records what you watch locally first; tracker accounts are an optional
mirror, never a requirement. A fresh install with no account gets working
Continue Watching, resume, and personalization.

## Local record

The player writes per-episode progress to `episode_progress` in the profile
database (schema v2), alongside a renderable snapshot of the show in
`watched_media` so rails draw instantly and offline. Writes ride the
engine's coalesced state stream — roughly one write per ten seconds of actual
playback, plus one on every exit or episode switch. There are no timers.

An episode latches **completed** when playback crosses the
`playerAutocompleteThreshold` setting (default 85%). Completion is sticky:
rewatching part of a finished episode updates its resume position but never
un-completes it. Positions under thirty seconds are treated as "barely
opened" and are neither resumed nor surfaced.

Opening an episode with a meaningful uncompleted position resumes from it;
completed or nearly-finished (≥95%) episodes start from the beginning.

## What reads it

- **Continue watching** on Home: local shows lead (ordered by when you last
  pressed play here), tracker-only Currently Watching entries follow.
- **For you**: genre affinity counts local history alongside the tracker
  list, so recommendations work signed out.
- The details modal and episode selector show watched state as the maximum
  of tracker progress and local completions, and open on the episode the
  player would come back to.

## Tracker sync — both directions

**Outward:** the first time an episode latches completed in a session, the
player calls `TrackingRepository.updateProgress`, which applies the ported
sync rules (never regress, auto-COMPLETED, repeat handling, offline
queueing) against AniList and mirrors to MAL when linked. No account, no
request.

**Inward:** the tracker's Currently Watching list merges into the rails and
progress display as above. A tracker outage or missing account never empties
the local rails.

**Connecting AniList:** the profile panel's *Connect AniList* opens the
implicit-grant authorization page in the browser; the user pastes back the
redirect address (or the bare token). The token is validated against the
Viewer endpoint before being stored in the OS keyring, and is only ever sent
to AniList itself with the `Bearer` scheme. Disconnecting deletes the stored
token and stops sync; local history stays.
