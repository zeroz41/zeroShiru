# Language-learning subtitles

zeroShiru's learning mode is a native, interactive subtitle surface for
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

translated text track ─► libmpv secondary cue + timing ─► aligned line below

AniList ID + episode ─► Jimaku read-only API ─► scored text subtitle
                                                   │
                                                   ▼
                                      bounded per-episode local cache
                                                   │
                                                   ▼
                                      libmpv external Japanese track
```

On entering Learning mode, optional automatic pairing chooses Japanese audio,
a Japanese text track as primary, and the configured learning language as
secondary. The
current implementation starts with English and can pair the other translation
languages already supported by the player's subtitle preferences. Translation
is authored subtitle text; zeroShiru does not generate or rewrite it.

If the release has no Japanese text track, zeroShiru can resolve one from
[Jimaku](https://jimaku.cc) using the AniList ID and episode already carried by
the playback request. Jimaku requires a free personal API key, stored in the OS
keyring. Direct ASS, SSA, SRT, and WebVTT files are supported, as are bounded
ZIP archives. The resolver rejects OCR/Whisper-labelled candidates, checks the
episode again locally, prefers release-name timing matches, verifies that the
chosen file contains Japanese text, and stores only that member in a
per-episode, per-release cache so differently timed WEB and Blu-ray variants do
not collide. A cached match is reused offline without another provider request.

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
never sent to the returned file host.

JMdict is created and maintained by the
[Electronic Dictionary Research and Development Group](https://www.edrdg.org/jmdict/j_jmdict.html)
and is used under the [EDRDG licence](https://www.edrdg.org/edrdg/licence.html).
The segmenter is the BSD-licensed
[TinySegmenter Dart port](https://pub.dev/packages/tiny_segmenter_dart), based
on Taku Kudo's TinySegmenter. Distribution notices live in
[`app/THIRD_PARTY_NOTICES.md`](../../app/THIRD_PARTY_NOTICES.md).

## User controls

All study behavior is dormant until **Learning** is selected in the subtitle
panel. Its settings control:

- automatic Japanese + translation text-track pairing;
- automatic retrieval of a missing Japanese episode track;
- Japanese surface text, furigana, romaji, and translated line visibility;
- pause on the first hover/tap lookup in each cue; and
- learning-overlay scale, independent of normal subtitles.

Hovering or tapping a token highlights it and opens its local base form,
reading, romanization, part of speech, and English definitions. The overlay
uses current primary and secondary cue timing independently, including each
track's delay.

## Product references and boundaries

The interaction model draws from Animelon-style parallel subtitle layers,
[Language Reactor's](https://www.languagereactor.com/help/basic) dual subtitles,
transliteration, and click-to-dictionary flow, and
[Migaku's](https://migaku.com/faq/features) interactive subtitle vocabulary.
The native mpv ecosystem also demonstrates the value of keeping text and
timing at the player boundary: [mpvacious](https://github.com/Ajatt-Tools/mpvacious)
uses primary/secondary mpv subtitles for sentence mining, while
[Voracious](https://github.com/rsimmons/voracious) pairs dual subtitles,
furigana, and hover definitions.

An opt-in artifact test can validate a downloaded release end to end with
`ZEROSHIRU_JMDICT_ARCHIVE=/path/JMdict_english.zip flutter test
test/learning/live_jmdict_artifact_test.dart`.

The first version intentionally does not include OCR, machine translation,
sentence explanations, flashcard export, or vocabulary history. Per-character
kanji readings are also not inferred; furigana is displayed at the verified
word level. Those can be added behind separate local capability ports without
changing standard playback or sending subtitle text away from the device.
