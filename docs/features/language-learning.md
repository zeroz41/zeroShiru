# Language-learning subtitles

Zero's learning mode is a native, interactive subtitle surface for
Japanese audio. It is deliberately separate from the normal subtitle renderer:
**Standard** remains the default and preserves ASS typesetting through
libmpv/libass; **Learning** trades authored positioning for selectable words,
readings, and local dictionary help.

There is no OCR path. Learning mode consumes the same timed text cues libmpv
already decodes from ASS, SRT, or WebVTT tracks. PGS and VobSub are bitmap
images, so the player asks for a Japanese text sidecar instead of pretending
that unreliable OCR output is authoritative.

## Data flow

```text
Japanese text track ─► libmpv cue + timing ─► cue identity ─► TinySegmenter
                                                           │
                                             local JMdict SQLite index
                                                           │
                                                           ▼
                                             tappable Flutter word widgets

translated text track ─► libmpv secondary cues + timing ─► overlap map
                                                                 │
                                                                 ▼
                                                translation context below

AniList ID + episode ─► Jimaku read-only API ─► scored text subtitle
                                                   │
                                                   ▼
                                      bounded per-episode local cache
                                                   │
                                                   ▼
                                      libmpv external Japanese track
```

The player remembers Standard, Learning, or Off as the active subtitle mode
and restores it when another episode opens. On entering Learning mode,
optional automatic pairing leaves the configured
audio track alone, chooses a Japanese text track as primary, and uses the
configured learning language as secondary. Returning to Styled mode clears the
secondary track and restores the configured main subtitle language. The
current implementation starts with English and can pair the other translation
languages already supported by the player's subtitle preferences. Translation
is authored subtitle text; Zero does not generate or rewrite it.

If the release has no Japanese text track, Zero can resolve one from
[Jimaku](https://jimaku.cc) using the AniList ID and episode already carried by
the playback request. Jimaku requires a free personal API key, stored in the OS
keyring. Direct ASS, SSA, SRT, and WebVTT files are supported, as are bounded
ZIP and 7z archives. The resolver rejects OCR/Whisper-labelled candidates,
checks the episode again locally, compares normalized release-group, platform,
source-cut, retime, and filename-token signals instead of requiring an exact
name, verifies that the chosen file contains Japanese text, and stores only
that member in a per-episode, per-release cache so differently timed WEB and
Blu-ray variants do not collide. A cached match is reused offline without
another provider request.

Each Japanese cue is segmented in a persistent background isolate without a
warm-up model or native NLP runtime. When JMdict is installed, the pipeline
checks increasingly long adjacent spans
and conservative candidates for common polite, negative, past, te-form,
desiderative, and adjective inflections. A candidate is used only when it
matches the local index. This lets a surface such as `食べました` resolve to
`食べる` without an LLM or a speculative definition.

## Local dictionary and privacy

The **Settings → Learning** install action downloads the English
[JMdict Yomitan release](https://github.com/yomidevs/jmdict-yomitan) from its
fixed GitHub project, validates the expected archive layout and size limits,
and builds a replaceable SQLite index in one transaction. Import work runs off
the UI isolate. The cache records the dictionary title, revision, source, and
entry count and can be updated or removed from the same settings panel. An
update replaces the index transactionally, so an interrupted refresh leaves
the previous dictionary usable.

After installation, word analysis and lookup are offline. No subtitle cue,
playback history, lookup, or media identity is sent to a dictionary service.
The network request contains only the public dictionary artifact URL. This is
also why the core definition experience does not use a local or hosted LLM:
JMdict is deterministic, source-attributed, fast, private, and usable on
low-power devices without hallucinated glosses.

Automatic subtitle acquisition is the one separate network operation: when it
is enabled and an embedded Japanese text track is missing, Jimaku receives the
public AniList ID and episode number. It does not receive subtitle cues,
lookups, playback position, or debrid URLs. Download redirects are
SSRF-checked, credentials are stripped across origins, and the Jimaku key is
never sent to the returned file host. For episodic shows, a direct subtitle or
archive member must explicitly name the requested episode before it can be
attached or cached; an API filter match alone is not accepted.

JMdict is created and maintained by the
[Electronic Dictionary Research and Development Group](https://www.edrdg.org/jmdict/j_jmdict.html)
and is used under the [EDRDG licence](https://www.edrdg.org/edrdg/licence.html).
The segmenter is the BSD-licensed
[TinySegmenter Dart port](https://pub.dev/packages/tiny_segmenter_dart), based
on Taku Kudo's TinySegmenter. Distribution notices live in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

## User controls

All study behavior is dormant until **Learning** is selected in the subtitle
panel. **Kanji**, **Kana**, **Romaji**, and **Translation** are direct toggles
there. Manual primary/secondary tracks, timing, and sidecars stay in a
collapsed **Advanced** section. Persistent settings also control:

- automatic Japanese + translation text-track pairing without changing audio;
- automatic retrieval of a missing Japanese episode track;
- Japanese surface text, furigana, romaji, and translated line visibility;
- pause on the first highlighted, focused, or tapped lookup in each cue; and
- one subtitle text-size preference shared live with normal text subtitles.

Before a manual track is chosen, playback infers missing language tags from
track titles and prefers main/full-dialogue tracks over commentary, forced,
or signs-and-songs variants. In Learning mode that yields Japanese text plus
the configured translation language while the user's audio preference remains
authoritative; explicit compatible subtitle picks win on subsequent
preparation.

Hovering a token highlights it and opens a compact local definition popover on
pointer devices. Touch keeps tap-to-select, while keyboard and TV-style input
uses focus as the highlight and Select/Enter as the toggle. Moving the pointer
or focus outside the learning surface fades the definition away; tapping the
same token or the close button also dismisses it. The popover includes the
base form, reading, romanization, part of speech, and English definitions. The overlay
records a bounded cue history and pairs all translated cues whose adjusted
time windows overlap the current Japanese cue, including a small boundary
tolerance and each track's delay. It never pairs unrelated lines merely because
they were the last cues observed. Authored subtitle tracks can still segment or
paraphrase dialogue differently, so this is intentionally translation context,
not a claim that independently authored lines are literal one-to-one
translations. Timeline dragging previews locally and commits one seek; the
player clears stale cue work during that seek and refreshes both active lines
after MPV settles. Unknown-duration cues also have a bounded display fallback.
The active Japanese line is bottom-anchored over the video with clean outlined
type, furigana above each word, optional romaji below it, and a full-size
outlined translation on its own line. MPV's active cue transition is the only
display clock; the overlay does not re-gate a new cue against Flutter's more
coarsely sampled position stream. Only lookup results and actionable warnings
use a surface; ordinary subtitles are rendered without a persistent opaque
panel.

Learning track intent is persistent rather than session-only. Choosing **Off**
for the secondary track also turns off the Translation layer, so switching to
Styled and back, opening another episode, or restarting the app does not
silently restore English. Choosing a secondary language again re-enables the
layer and makes that language the future automatic-pairing preference. Release
ranking also stops rewarding translated subtitles while that layer is off.

When several Jimaku files name the requested episode, the matcher compares the
torrent name and resolved video filename with normalized release groups,
streaming platforms, WEB/Blu-ray/broadcast cuts, and explicit “synced to” or
“retimed for” markers. These are independent evidence signals, not an exact
filename comparison. Archive metadata remains part of the score even when the
episode member has a generic name, and ZIP/7z members are checked independently.
Format is only a final tiebreaker. An unlabelled
debrid episode gets a small WEB preference, while NTV, AT-X, and other
broadcast captions win only for a compatible broadcast release. OCR, Whisper,
subgen, and other generated files are rejected. If Jimaku's best-effort episode
filter misses an unnumbered archive, the exact AniList entry is retried without
the filter and every member is still checked locally for the requested episode
and Japanese text. The attached track and preparation result retain the
selected catalog filename so a timing source is visible instead of becoming an
anonymous cached file. The release-aware cache prevents an older mismatched
candidate from being reused for the same video source.

The main release list uses the same persisted intent as playback: the chosen
audio language is the first language signal; Standard uses the regular
subtitle language, Learning uses its translation language, and Off does not
rank releases by subtitles. Manual audio/language and subtitle-mode changes in
the player update those defaults for the next episode. Primary and secondary
timing corrections are remembered separately for each release identity, so a
pack keeps its sync adjustment across episodes without shifting unrelated
encodes.

## Product references and boundaries

The interaction model draws from Animelon-style parallel subtitle layers,
[Language Reactor's](https://www.languagereactor.com/help/basic) dual subtitles,
transliteration, and click-to-dictionary flow, and
[Migaku's](https://migaku.com/faq/features) interactive subtitle vocabulary.
The native mpv ecosystem also demonstrates the value of keeping text and
timing at the player boundary: [mpvacious](https://github.com/Ajatt-Tools/mpvacious)
uses primary/secondary mpv subtitles for sentence mining, while
[Voracious](https://github.com/rsimmons/voracious) pairs dual subtitles,
furigana, and click definitions.

An opt-in artifact test can validate a downloaded release end to end with
`ZERO_JMDICT_ARCHIVE=/path/JMdict_english.zip flutter test
test/learning/live_jmdict_artifact_test.dart`.

The read-only Jimaku integration can be checked against the current catalog
with `ZERO_LIVE_JIMAKU_KEY='…' flutter test
test/learning/live_jimaku_test.dart`.

The first version intentionally does not include OCR, machine translation,
sentence explanations, flashcard export, or vocabulary history. Per-character
kanji readings are also not inferred; furigana is displayed at the verified
word level. Those can be added behind separate local capability ports without
changing standard playback or sending subtitle text away from the device.
