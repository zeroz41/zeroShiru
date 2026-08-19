# Phase 0 — Migration Baseline

Recorded: 2026-08-19, branch `redo`, version 6.8.0 (electron/package.json).

## Toolchain at freeze
- Node v26.4.0, pnpm 11.3.0 (`packageManager: pnpm@10.34.1` in electron workspace — drift, root uses pnpm 11)
- Rust 1.89.0 available; Bun and Tauri CLI not yet installed
- node_modules (root, hoisted): ~1.1 GB
- Source files (js + svelte, non-vendored): 266

## Test baseline
- `node --test test/unit/**` → **332 pass / 0 fail** (~14.6 s)
- Live tests exist under `test/live/` (network, concurrency 1) — not part of CI gate here

## Build graph at freeze
- `common/webpack.config.cjs` — factory producing the **renderer** bundle (Svelte 4,
  target `web`, Buffer ProvidePlugin, MiniCssExtract, HtmlWebpackPlugin template,
  CopyWebpackPlugin from `common/public`). Consumed by:
  - `electron/webpack.config.cjs` → four bundles: background (electron-renderer,
    devServer :5000), renderer (`app.html`), preload, main
  - `capacitor/webpack.config.cjs` → two bundles: node background (`build/nodejs/index.js`,
    devServer :5001, `bridge` external for capacitor-nodejs) and renderer (`index.html`)
- `pnpm-workspace.yaml`: `shamefullyHoist: true` REQUIRED by webpack `../node_modules`
  aliasing; `blockExoticSubdeps: false` for git-dep chain (matroska-metadata → ebml-iterator);
  6 patched deps; native build allowlist.

## Existing architecture assets (report corrections)
- **Platform bridge already exists**: `common/modules/bridge.js` is the ONLY file in
  `common/` referencing Electron. It defines TORRENT / COMMON / ANDROID / ELECTRON op
  surfaces with noop defaults, injected by hosts via `window.torrent` etc.
  → Phase 3 (service boundaries) = extend/formalize this, not create from scratch.
  → Tauri host = implement the same window.* surface.
- **Four debrid providers**, not two: AllDebrid, Premiumize, RealDebrid, TorBox under
  `common/modules/debrid/` with shared base (`debrid.js`), availability, pick, route,
  identity, metadata, service layers.
- **16 debrid + 8 playback unit-test files** = golden vectors for the Rust port.
- `extensions/` workspace = dynamic source/addon system; needs explicit decision
  (see 01-parity-checklist.md).

## Performance/footprint baseline (to compare post-migration)
| Metric | Value |
|---|---|
| Root node_modules | 1.1 GB |
| Unit suite wall time | 14.6 s |
| Electron version | 42.3.0 |
| Renderer bundles | webpack 5, source-map, dev :5000 |

Startup-time / RSS numbers require a display session; capture manually before deleting
Electron (Phase 10 gate).
