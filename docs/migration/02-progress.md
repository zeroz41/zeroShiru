# Migration Progress

Updated: 2026-08-19 (branch `redo`). One commit per phase; `git log --oneline`
reads as the migration timeline.

## Landed

| Phase | State | Evidence |
|---|---|---|
| 0 baseline | done | 00-baseline.md, 01-parity-checklist.md |
| 2 Webpack→Vite (renderer) | done | `common/vite.config.mjs`; electron/capacitor node bundles stay webpack until 8-13 |
| 1 pnpm→Bun (hoisted) | done | bun.lock authoritative; CI on bun; lucide patch retired |
| 3 service boundaries | pre-existing | bridge.js was already the only host seam; now merges host overrides over noop defaults |
| 4 Rust workspace | done | 10 crates + wasm-bridge; portable set builds for wasm32 |
| 6 debrid → Rust | done* | 4 providers + manager, 109 tests mirroring test/unit/debrid; *TODOs: shared TTL listing cache, orphan-retry replay |
| 7 Tauri desktop | shell up | boots the Vite renderer; NVIDIA/Wayland graphics auto-fallback (reproduced the report's Error 71 on this machine) |
| 8 torrent → Rust | engine core | librqbit behind TorrentEngine; loopback gateway (token, range); live-verified vs a real swarm (206, 64KiB in ~0.9s, 6 peers) |
| 9 desktop integration | partial | window controls, exit-intent modal flow, dialogs, notifications, devtools, Discord RPC; missing: tray, updater, protocol handler, DoH, logging |
| 12 Android | APK builds | cargo tauri android → app-universal-debug.apk (aarch64), same Rust core + renderer; device testing + Kotlin adapters pending |
| 15 WASM core | seed | scripts/build-tv-core.sh → 160KB wasm + web glue (route/normalize/parse + matroska); executed with native-identical results |
| 16/17 TV hosts | scaffolds | hosts/tizen (config.xml access list = section-11 gate), hosts/webos (spike-first README) |

## Running things

```
npm test                      # 332 JS unit tests
cargo test --workspace        # 160+ Rust tests
npm run tauri:dev             # vite :5173 + Tauri window (SHIRU_GRAPHICS=safe if graphics act up)
cd electron && npm start      # the Electron path, still fully working
./scripts/build-tv-core.sh    # dist/tv-core WASM bundle
cargo run -p shiru-torrent --features native --example smoke   # live torrent smoke
```

## The honest gaps (what "parity" still means)

1. **Frontend still speaks JS-webtorrent.** The TORRENT bridge surface
   (onStats/onFiles/subtitle extraction/fonts/chapters/session restore) is
   implemented by the webtorrent background process. The Rust engine covers
   add/metadata/select/stream/stats + pushed status events; crates/media now
   parses Matroska heads (tracks/codecs/languages/ASS CodecPrivate) from
   ranged bytes — the cue/attachment extraction pass is the remaining piece.
2. **Debrid UI path**: window.shiru.debrid.* works end to end, but
   common/modules/debrid/*.js remains the code the UI runs. The swap is a
   frontend service-layer change gated on (1) events and error-shape parity.
3. **Updater**: needs Tauri signing keys — a release-owner decision.
4. **Tray, protocol handler (shiru://), DoH, log export**: not started.
5. **Android**: APK assembles; needs on-device run + the Kotlin adapter layer (Media3 player, PiP, foreground service, SAF, notifications).
6. **TV**: both hosts are scaffolds; the report's hardware gates (sections 11
   and 28) are deliberately unskippable and need physical TVs.
7. **Extension system decision** (01-parity-checklist.md) still open — blocks
   crates/sources beyond normalization.

## Rollback

Every phase is one commit on `redo`; Electron/webpack paths still build and run
at every commit since c413c7a6.
