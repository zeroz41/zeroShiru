# Migration Progress

Updated: 2026-08-19 (branch `redo`). History was squashed into `initial tauri
rewrite`; work continues as small commits on top.

## Where things stand

The legacy stacks are gone. There is no Electron, no Webpack, no Capacitor/
Cordova/node-mobile, no WebTorrent, and no npm in any workflow — Bun runs the
JS side, Cargo runs the Rust side.

| Area | State |
|---|---|
| Frontend build | Vite only (`bun run build` → `dist/web`), Svelte 4 preserved |
| Desktop host | Tauri 2 (`hosts/tauri`): window/tray/dialogs/notifications, deep links, single instance, Discord RPC, NVIDIA/Wayland graphics fallback |
| Torrenting | Rust (`crates/torrent`): librqbit behind `TorrentEngine`, plus `TorrentSession` — role registry (current/staging/seeding/completed), sidecar persistence, auto-restore, seeding-limit policy, HTTP tracker scrape, external player launch, loopback range gateway for playback |
| Torrent UI wiring | One pushed `stats` snapshot drives all four Svelte stores; `files` events carry gateway URLs with the debrid-identical `fileHash` watch key |
| Debrid | Rust (`crates/debrid`, 4 providers) behind `window.shiru.debrid`; the JS providers in `common/modules/debrid/` still run the UI path (swap pending) |
| Subtitles/metadata | Renderer-side `DebridMetadata` (HTTP-range Matroska parsing) now serves BOTH lanes — torrent and debrid — off the gateway/debrid URL |
| Protocol handling | Renderer-side `common/modules/protocol.js` (shiru://, magnet:); hosts only deliver raw URLs |
| Bridge | `common/modules/bridge.js` rewritten lean: TORRENT (19 ops), COMMON, ANDROID, DESKTOP; only file in common/ touching a host API |
| Android | Tauri Android APK assembles from the same core; Kotlin adapters (Media3, PiP, foreground service, SAF) not started |
| TV | 160KB WASM core builds; `hosts/tizen` + `hosts/webos` scaffolds, hardware-gated |
| Tests | 332 JS (`bun run test`, node:test) + 160+ Rust (`cargo test --workspace`), all green |

## What's left to finish

1. **Live-run the desktop app** — the rewritten torrent path (session, snapshot
   events, gateway playback, renderer-side subtitle extraction for torrents)
   compiles and is unit-tested but has not yet streamed a real torrent end to
   end under the Tauri window. First manual smoke: `bun run tauri:dev`, load a
   magnet, check files/stats/subtitles/seek.
2. **Debrid UI swap** — point `common/modules/debrid/` service calls at
   `window.shiru.debrid.*` and delete the JS provider implementations.
3. **Updater** — Tauri updater needs signing keys (release-owner decision);
   the bridge ops are noops until then.
4. **Desktop odds and ends** — DoH, ANGLE selection, log export/reset,
   unread-count badge: bridge noops today, need Rust/host equivalents or
   deliberate removal.
5. **Android (phase 12/13/14)** — Kotlin adapters, on-device testing, then
   Android TV input/layout profile.
6. **Anime filename parsing → Rust** (anitomyscript replacement) and
   remaining §18 package audit (comlink, video-deband, quartermoon…).
7. **TV hosts** — section 11/28 hardware gates, then real bootstraps.
8. **Svelte 5** — last, as its own project (phase 18).

## Known behavior changes (deliberate, from the clean rewrite)

- Session state lives in Rust (`shiru-session.json` next to the download dir);
  the frontend no longer caches torrent lists.
- `reannounce` is gone (librqbit reannounces on its own schedule).
- Seeder/leecher splits in the torrent manager show connected peers until a
  tracker scrape fills totals.
- Rescan no longer re-hashes; the engine verifies on add instead.
- uTP/PeX toggles are accepted but inert (librqbit manages transports).

## Running things

```
bun run test                # 332 JS unit tests
cargo test --workspace      # Rust tests
bun run tauri:dev           # Vite :5173 + Tauri window (SHIRU_GRAPHICS=safe if needed)
bun run build               # production frontend → dist/web
./scripts/build-tv-core.sh  # WASM TV core
```

The user's live desktop session: never launch GUI apps or take screenshots
while it is in use.
