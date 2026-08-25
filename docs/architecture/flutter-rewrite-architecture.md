---
title: "zeroShiru Flutter Rewrite"
subtitle: "Pure Dart/Flutter architecture — no Rust, no web runtime"
author: "Repository-specific engineering report"
date: "23 August 2026"
lang: en-US
toc: true
toc-depth: 3
numbersections: true
---

> **Decision in one sentence:** zeroShiru is rewritten as a single pure-Dart Flutter application — Impeller renders the UI, libmpv (via pinned `media_kit`) renders video into a Flutter external texture, and every service that used to live in Rust (debrid, sources, torrenting, the loopback Range gateway) is reimplemented in Dart behind stable ports. No Rust, no Cargo, no Node, no WebView, anywhere.

This revision supersedes the earlier report that recommended retaining a Rust core during migration. That recommendation is **overruled by product decision**: zero Rust is a hard goal, and the rewrite happens clean-slate on the `flutter` branch. The old Tauri/Svelte application remains intact on `zeroz-dev`/`redo` as the working fallback and as the reference for behavior; it is not kept buildable on this branch.

# Executive summary

## What is being built

| Concern | Decision |
|---|---|
| UI runtime | Flutter 3.47+, Impeller (default on Linux/Windows/macOS/mobile) |
| Language | Dart only — application, services, and platform glue |
| Video | libmpv render API → Flutter external texture, via pinned `media_kit` |
| Subtitles | libass for fidelity (standard mode); Flutter overlay for learning mode |
| Debrid / tracking / sources | Pure Dart HTTP services, ported from proven Rust/JS behavior |
| Torrent streaming | Pure Dart engine + loopback Range gateway (`dart:io`), after debrid parity |
| State | Riverpod, hand-written providers; no build_runner/codegen until proven necessary |
| Storage | SQLite (`sqlite3` + FFI) as source of truth; OS keyring for secrets |
| TV targets | Flutter-Tizen (6.0+/2021+) and Flutter webOS (TV 26 Re:New+) later, native players behind the same `MediaEngine` port |
| Legacy stack | Svelte, Tauri, WebKit, Vite, Node, all eleven Rust crates: **deleted on this branch** |

## Why pure Dart is now acceptable

The earlier report kept Rust because torrent/debrid behavior was live-proven and porting it alongside a UI rewrite doubled the regression surface. Three things change the calculus:

1. **Debrid is the primary daily path.** Debrid providers are plain HTTPS APIs — Dart's HTTP stack reproduces them directly, and the existing Rust/JS tests become Dart golden fixtures. This is a low-risk port.
2. **The Range gateway is just an HTTP server.** `dart:io`'s `HttpServer` on loopback serves `206`/`Content-Range` semantics fine; piece-aware prioritization is application logic, not systems programming.
3. **Torrenting is scoped, not general.** zeroShiru needs a streaming-focused subset (magnet resolution, tracker announce, sequential/priority piece scheduling, seeking), not a general-purpose BitTorrent library. That subset is tractable in Dart on `dart:io` sockets, and it lands *after* the app is already useful in debrid mode. External mpv handoff remains the escape hatch throughout.

The honest cost: the pure-Dart torrent engine is the riskiest single component and is deliberately sequenced last. Everything else in the app does not wait for it.

## What must be preserved (behavior, not code)

- The four debrid integrations (AllDebrid, Premiumize, Real-Debrid, TorBox) with their cached-availability routing, slow-link handling, rate/retry semantics, and the flapping-service degradation.
- Pack selection, filename recognition, and episode mapping.
- Signed-URL redaction everywhere: logs, process args, UI state, crash reports.
- AniList/MyAnimeList sync rules, watch-progress thresholds, resume, chapters, skip.
- The current visual design language (cinema hero, accent pills, titled rails, soft posters, ambient depth) — the Flutter theme reproduces it.
- Existing unit-test vectors as cross-language golden fixtures.
- User rule: **no torrent toasts in debrid mode, ever.**

# Target architecture

The core rule is **dependency inversion around capability ports**. Features depend on Dart interfaces; adapters (libmpv, HTTP services, SQLite, TV players) implement them. No screen imports a plugin or FFI binding directly.

## Layers

- **Presentation** — Flutter widgets: layout, focus, keyboard/remote/touch input, animation. Two responsive shells from one feature set: touch/compact (bottom nav, gestures) and desktop/TV (rail, shortcuts, D-pad focus traversal). Player controls are Flutter overlays above the video texture.
- **Application** — Riverpod controllers coordinating search, detail loading, playback startup, source routing, history, tracking sync. They consume streams and publish immutable view state; high-frequency native events (position, cache) are coalesced to a few UI updates per second.
- **Domain** — models and ports, no Flutter imports. Key ports: `MediaEngine`, `SourceResolver`, `DebridClient`, `TorrentEngine`, `LibraryRepository`, `TrackingRepository`, `SettingsRepository`, `CredentialStore`, `LearningService`, `WatchTogetherTransport`.
- **Infrastructure** — Dart adapters: HTTP clients (AniList/MAL, debrid providers), SQLite repositories, secure settings, image cache, the loopback Range gateway, `media_kit` behind `MediaEngine`, platform windowing/tray/deep-link plugins.

## Repository layout

```text
zeroShiru/
  app/                       # the Flutter package — the whole application
    lib/
      app/                   # bootstrap, router, theme, l10n
      domain/                # models and ports; no Flutter imports
      application/           # Riverpod controllers and use cases
      features/
        home/ search/ details/ player/
        downloads/ watch_together/ settings/ learning/
      infrastructure/
        network/ debrid/ sources/ torrent/
        database/ tracking/ media/ platform/
      l10n/                  # ARB inputs
    test/                    # unit + widget tests, golden fixtures
    integration_test/
    linux/ windows/ macos/ android/
  fixtures/                  # cross-language golden vectors (from old Rust/JS tests)
  docs/architecture/
  platforms/                 # later: tizen/ webos/ vendor runners + media adapters
```

## Boundary rules

- One user gesture → one command; one native state transition → one event. Never per-frame Dart↔native calls; never decoded pixels through Dart.
- Heavy CPU work (tokenization, torrent piece hashing, parsing large metadata) runs in Dart isolates, never the UI isolate.
- `MediaEngine` and `SourceResolver` are the two seams every platform adapter must satisfy; capability shortfalls degrade explicitly, never silently.

Representative contracts:

```dart
abstract interface class MediaEngine {
  Stream<PlaybackSnapshot> get state;
  Stream<SubtitleCue> get primaryCues;
  Stream<SubtitleCue> get secondaryCues;
  Stream<PlayerMetrics> get metrics;
  Future<void> open(MediaSource source, {ResumePoint? resume});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> selectAudio(TrackId? id);
  Future<void> selectSubtitle(TrackId? id, {bool secondary = false});
  Future<void> setSubtitleRendering(SubtitleRendering mode);
  Future<void> dispose();
}

abstract interface class SourceResolver {
  Future<ResolvedPlayback> resolve(PlaybackRequest request);
}
```

# Video architecture: libmpv inside Flutter

## Embedding mechanism

Use libmpv's render API into a Flutter external texture — not `--wid`, not a child mpv window (Wayland makes foreign-window embedding undependable). The path:

1. Flutter creates a texture-backed viewport; the plugin owns the libmpv handle and render context.
2. A dedicated native render thread receives frame notifications and renders into the platform texture via GPU interop.
3. Impeller composes the texture with Flutter controls/overlays.
4. After presentation, `mpv_render_context_report_swap()` is called so mpv can pace display-synchronized video.
5. A separate event loop observes libmpv properties and sends low-rate structured state to Dart.

## media_kit, pinned

`media_kit` (with `media_kit_video`, `media_kit_libs_video`) already provides libmpv FFI, texture registration, hardware acceleration, and track selection across desktop/mobile. Pin exact versions/commits. Known open issues are acceptance tests, not disqualifiers:

- Linux: texture path reportedly skips `mpv_render_context_report_swap()` → judder on some hardware while standalone mpv is smooth. Verify on the actual NVIDIA/Wayland machine; patch via a narrow fork if upstream stalls.
- Android: bitmap-subtitle (PGS) rendering and resize/orientation reports — release gates for mobile.

The first Linux release probe selected the narrow-fork option. Flutter's UI was
already on Impeller/OpenGL ES, but `media_kit_video` 2.0.1 silently selected its
software pixel-buffer texture because the plugin assumed Flutter's EGL context
would be current while GTK handled a platform-channel call. Flutter makes no
such platform-thread guarantee. The vendored 2.0.1 patch creates a temporary
OpenGL ES context from the realized `FlView` GTK window when necessary, lets GDK
select the native display and driver, creates the existing isolated mpv EGL
context, then releases the bootstrap context. It contains no GPU-vendor checks
or session environment overrides. The NVIDIA/Wayland release probe now reports
both Impeller OpenGLES and `VideoOutput: H/W rendering with isolated EGL
context`; a real lack of EGL support may still take the documented fallback.

The `MediaEngine` port keeps the rest of the app ignorant of media_kit, so a fork, replacement plugin, or platform-native adapter never touches screens.

## Configuration and diagnostics

Versioned application profile, not a personal `mpv.conf`: safe automatic hwdec with software fallback, `embeddedfonts=yes`, libass on, mpv input/OSC disabled (Flutter owns controls), mpv log callback routed into redacted structured logs, resume handled by zeroShiru, user scripts off, protocol allow-list (file, https, loopback gateway). Confirm hardware decode via `hwdec-current`; never infer it.

A developer diagnostics panel exposes: `hwdec-current`, `avsync`, drop/mistimed/vsync counters, cache state, display vs media FPS, texture size/resize count, open- and seek-to-first-frame. This makes "it stutters" falsifiable.

## Fallback ladder

1. In-app libmpv hardware path.
2. In-app software decode (with a warning for high-resolution media).
3. External mpv/VLC handoff, preserving the secure stdin URL-passing behavior from the old app.

Fallback never silently changes subtitle tracks or loses progress sync; external playback declares its reduced capabilities.

# Dart core services (replacing Rust)

## Debrid

One Dart package-internal module per provider (AllDebrid, Premiumize, Real-Debrid, TorBox) behind a common `DebridClient` port. Port from the Rust implementations: endpoints, auth, cached-availability checks, unlock/signed-URL flow, per-endpoint timeout and retry, and the degradation added for flapping services (mark endpoint quiet, keep the rest of the provider useful, surface state to the UI without toast spam). Golden fixtures come from the existing Rust tests and captured live responses.

## Sources

Remote-JavaScript extensions are replaced by a versioned **declarative source manifest**: allowed hosts and redirect policy, request templates, auth by reference, JSON/HTML/RSS selectors, pagination, normalization and episode mapping, rate limits, cache policy, plus fixtures with expected output. A Dart engine validates and executes manifests with SSRF/private-network protection and credential redaction. No embedded JS runtime; arbitrary remote code does not return.

## Filename recognition and pack selection

Port the recognition/selection logic (release parsing, episode mapping, quality/codec extraction, batch handling, safety checks) to pure Dart with the existing test vectors as the spec. This logic is deterministic and fixture-heavy — the easiest and highest-value port.

## Loopback Range gateway

A `dart:io` `HttpServer` bound to `127.0.0.1` on an ephemeral port:

```text
http://127.0.0.1:<port>/v1/stream/<opaque-id>?cap=<random-capability>
```

Unguessable short-lived capability tokens; `HEAD`, single byte ranges, `206`, `Content-Range`, stable length, cancellation, backpressure; requested-range-plus-window prioritization when fed by the torrent engine; token revoked at playback close; query strings redacted from logs. Debrid URLs go **direct to libmpv** where headers/redaction allow — the gateway is required only for torrent data and providers whose credentials must be hidden.

## Torrent engine (last, and honestly the riskiest)

A streaming-focused pure-Dart engine on `dart:io` sockets: magnet/metainfo handling, tracker announce (HTTP/UDP), peer wire protocol, sequential/priority piece scheduling driven by the gateway's requested ranges, seeking, resume metadata in SQLite. Explicitly out of scope initially: seeding optimization, DHT (add later if needed), uTP. Sequenced after debrid parity so the app is fully usable while this matures. External mpv handoff and debrid remain the fallbacks if a given swarm outruns the engine.

## Tracking

AniList (GraphQL) and MyAnimeList (REST) clients in Dart, preserving the existing sync rules: progress thresholds, when a watch counts, conflict handling, offline queueing.

# Subtitles, languages, and Japanese learning

## Two explicit modes

**Standard mode — fidelity first.** libmpv/libass renders subtitles into the video output: embedded/external ASS with fonts and typesetting, SRT, PGS where the platform build supports it, primary + `secondary-sid`. This deletes the entire JASSUB/WASM/Canvas pipeline and most of the old subtitle scheduler.

**Learning mode — interaction first.** Keep the track selected/decoded but set `sub-visibility=no`; observe `sub-text`, `sub-start/end`, `secondary-sub-text` and render the cue as native Flutter token widgets (pause, highlight, reading, base form, glosses, sentence translation). This trades exact ASS positioning for interaction; the user can switch modes at any time. Bitmap tracks show an explicit "interactive text unavailable" state.

When an episode has no Japanese text track, a separate
`LearningSubtitleRepository` may resolve one by stable AniList ID + episode.
The Jimaku adapter uses a personal key from OS credential storage, rejects
OCR/generated candidates, bounds direct files and ZIP expansion, caches one
verified text member per episode, and gives libmpv a local file URI. Provider
authentication is never forwarded to download hosts.

## Cue identity and stale-result safety

Every cue carries `player_generation + track_id + start_ms + end_ms + normalized_text_hash`. Async results (tokenization, dictionary, translation) apply only if the identity still matches; generation increments on every open; outstanding work is cancelled on seek/track-change/dispose. Tokenization and dictionary results are cacheable by normalized text + tokenizer/dictionary version.

## Japanese pipeline

Segment short cues in a persistent isolate with the pure-Dart TinySegmenter
model, then enrich likely word spans against a local SQLite index built from
the English JMdict Yomitan release. Conservative inflection candidates are
never presented as facts: a
candidate must exist in the installed dictionary before its base form, reading,
part of speech, or definition is shown. The large archive import runs in an
isolate and records its source revision and entry count. Keep the TinySegmenter
BSD notice and the JMdict/EDRDG attribution and license with distributions.
See [the feature design](../features/language-learning.md).

## Language model

Three separate concepts: application locale (ARB/`gen_l10n`), preferred media languages (ordered BCP 47 for audio/primary/secondary, original container tags retained), learning languages. Track selection: exact tag → base language → forced/default preferences → remembered per-show choice → explicit off. Source lists use the same media-language preferences as strong ranking signals when providers report them, and conservative filename hints otherwise; incomplete metadata never hard-filters a playable result. Never assume UI locale implies subtitle language.

# Platform strategy

| Target | Floor | Media path | Notes |
|---|---|---|---|
| Linux | Flutter's supported distros | libmpv texture | First-class acceptance platform; test Wayland + X11, Mesa + NVIDIA; AppImage/deb with pinned libmpv/FFmpeg/libass |
| Windows | Win 10/11 | libmpv texture | HiDPI/mixed-DPI, resize/fullscreen, bundled DLLs + notices |
| macOS | macOS 12+ | libmpv texture | Sign/notarize app and bundled libs |
| Android / Android TV | Impeller floor | libmpv; Media3 adapter feasible | Rotation/PiP/audio-focus gates; TV needs real-device focus + codec tests |
| Tizen TV | 6.0 / 2021+ | AVPlay/video-hole | flutter-tizen; no desktop libmpv on TV |
| webOS TV | TV 26 Re:New+ | `video_player_webos` | Official but young; isolate the adapter |
| Older 2020-era TVs | **Unsupported** | — | Confirmed decision; no legacy web client is retained |
| Web | Not a target | — | The web target never dictates architecture again |

TV adapters implement the `MediaEngine` subset the device supports and report unavailable capabilities; initial TV parity is playback/tracks/progress/focus, not learning overlays.

# Data, security, and operations

## Storage

SQLite is the source of truth: profiles, typed settings (with schema version), watch history/progress, media cache (provider/version/expiry), torrent resume metadata, track preferences per show/release, learning state, dictionary metadata, migration journal. Secrets live in OS credential storage; SQLite holds only opaque references. Persist durable domain facts, never UI state graphs.

## One-time import from the old app

The old app (on `zeroz-dev`) gains/retains an "export migration bundle" command producing versioned JSON with non-secret data and credential references; the Flutter app imports it idempotently with a journal. Secrets are re-read from the platform keyring where possible, otherwise the user reauthenticates. Scraping WebKit profiles directly is a non-goal.

## Security boundaries

- Debrid URLs are bearer credentials: never in process args, logs, analytics, UI state, or error messages; centralized URL sanitizer.
- Range gateway: loopback only, capability tokens with expiry.
- SSRF/private-IP/redirect guards on all source manifests and HTTP adapters (port the Rust networking guards' semantics).
- mpv scripts/config discovery disabled by default; protocol allow-list.
- OS keychain for debrid/tracking tokens; signed update metadata; license notices screen (mpv/FFmpeg/libass/JMdict).
- Translation/lookup features that send text off-device are opt-in and labeled.

## Observability

Bounded rotating structured logs (the "page writes to main.log" property is kept: one log for host and app). A user-exportable diagnostic bundle: versions, OS/GPU/display facts, media adapter + libmpv version, redacted player metrics, state transitions and error chains — no tokens, no signed URLs, no subtitle text by default. A frame-timing overlay works without a debugger.

# Roadmap (clean slate)

The old strangler plan is replaced: this branch starts empty and builds up. The old app is the reference implementation on other branches, not a co-resident build.

| Phase | Deliverable | Exit criterion |
|---|---|---|
| 1. Foundation | Flutter package, theme reproducing the current design, router, l10n, CI, lint/test lanes | Linux release build runs; theme review against old app screenshots |
| 2. Library slice | AniList auth + home (cinema hero, rails) + search + details + SQLite cache/settings | Daily browsing works offline-tolerant |
| 3. Player | media_kit playback, controls, tracks, chapters, progress, resume, external-mpv fallback; swap-timing verified on the NVIDIA/Wayland machine | Reference media matrix passes; cadence ≈ standalone mpv |
| 4. Debrid | Four providers in Dart, cached-availability routing, pack selection/filename recognition with golden fixtures, direct-URL playback | Old-app parity on debrid daily path; no torrent toasts in debrid mode |
| 5. Tracking + polish | MAL, progress sync rules, schedule, notifications, downloads UI | Golden/live workflow tests pass |
| 6. Gateway + torrent | Dart Range gateway, then the streaming torrent engine | Smooth playback from a healthy swarm; external fallback intact |
| 7. Release | Installers/AppImage, updater, deep links, import-from-old-app | Signed beta passes desktop gates |
| 8. Android, then TVs | Mobile lifecycle/PiP, then Tizen/webOS adapters | Real-device matrices pass |
| 9. Learning | Tokenizer + JMdict + interactive overlay | Cue identity survives seek/track-switch |

Performance gates (release builds only): p99 UI frames inside 16.7 ms on the baseline 60 Hz Linux machine; input response < 50 ms; no recurring cadence judder vs standalone mpv; hardware decode confirmed via `hwdec-current`; seek-to-first-frame < 400 ms for local/cached sources. The Phase-3 player gate on the affected Linux hardware is still the go/no-go for the media plugin choice (patch, narrow fork, or owned minimal plugin — in that order).

# Verification

- **Pure Dart unit tests** for domain policies, language matching, cue identity, selection logic, source manifests — with the old Rust/JS test vectors imported as fixtures under `fixtures/`.
- **Widget/golden tests** for responsive layouts, focus order, l10n overflow — behavioral assertions (focus, semantics, shortcuts), not screenshots-only. Per repo rule: no GUI/screenshot tests that drive the real app in the repo.
- **`MediaEngine` contract suite** run against every adapter: open→ready-or-typed-error, superseding open invalidates prior events, ordered seeks, stable track IDs per generation, dispose releases textures, progress never moves backward except on explicit seek/restart, fallback reports reduced capability.
- **Integration tests** with fake providers and deterministic media; **live tests** (debrid/tracking/torrent) serialized, secret-gated, opt-in only — live torrenting stays opt-in per repo rule.
- **CI lanes**: fast (format/analyze/unit) per change; Linux integration per change; Windows/macOS on protected branches; Android emulator functional + scheduled device media tests; dependency lane (lockfile diff, license inventory, pinned media versions).

## Dependency budget

Fewer than 15 direct general-purpose Dart dependencies before platform packages: Riverpod, one router (or Router API), one HTTP stack, sqlite3, secure storage, path/window/tray as needed, pinned media_kit set, `flutter_localizations`/`intl`. Every addition needs an ADR-style justification; exact pins for anything native.

# Decisions to record as ADRs

1. Pure Dart / zero Rust (this document; supersedes the retain-Rust recommendation).
2. media_kit pin/fork vs owned minimal plugin — narrow vendored Linux patch selected by the Phase-3 EGL gate; cadence/swap timing remains an acceptance gate.
3. Declarative source-manifest format and security policy.
4. SQLite schema, export/import, secret ownership.
5. Standard-vs-learning subtitle modes.
6. TV OS minimums (Tizen 6.0+/webOS TV 26 Re:New+; no legacy client).
7. Torrent engine scope (streaming subset) and its fallback ladder.
8. Dependency admission policy and performance budgets.

# References

1. Flutter — [Impeller](https://docs.flutter.dev/perf/impeller), [desktop support](https://docs.flutter.dev/platform-integration/desktop), [supported platforms](https://docs.flutter.dev/reference/supported-platforms), [internationalization](https://docs.flutter.dev/ui/internationalization).
2. mpv — [manual](https://mpv.io/manual/stable/), [render.h](https://github.com/mpv-player/mpv/blob/master/include/mpv/render.h), [libmpv examples](https://github.com/mpv-player/mpv-examples/blob/master/libmpv/README.md), [licensing](https://github.com/mpv-player/mpv/blob/master/Copyright).
3. media-kit — [repository](https://github.com/media-kit/media-kit); issues [#1425](https://github.com/media-kit/media-kit/issues/1425) (Linux swap report), [#1426](https://github.com/media-kit/media-kit/issues/1426) (Android PGS), [#1395](https://github.com/media-kit/media-kit/issues/1395) (mobile resize).
4. Samsung — [flutter-tizen](https://github.com/flutter-tizen/flutter-tizen), [plugins](https://github.com/flutter-tizen/plugins). LG — [Flutter for webOS TV](https://webostv.developer.lge.com/news/flutter-for-webos-tv-is-now-available-for-developers), [plugin list](https://github.com/lg-flutter-webos/plugins/blob/main/doc/plugin-list.md).
5. EDRDG — [JMdict](https://www.edrdg.org/jmdict/j_jmdict.html), [license](https://www.edrdg.org/edrdg/licence.html).

# Appendix: player state model

```text
generation
phase: idle | opening | ready | playing | paused | buffering | ended | failed
source_id
position / duration / buffered
volume / mute / speed
video_size / rotation / aspect
audio_tracks[] / selected_audio
subtitle_tracks[] / selected_primary / selected_secondary
chapters[]
subtitle_rendering: standard | learning | off
capabilities
typed_error
```

Seek commands carry an ID and produce acceptance/completion/failure so an old completion cannot overwrite a newer seek. `MediaTrack` keeps `languageOriginal` (raw container tag) beside normalized BCP 47 `language`; unknown stays `und` — never manufacture a language from a title without marking the inference.
