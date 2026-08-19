# Building zeroShiru

The app is a Svelte frontend on a shared Rust core, hosted by Tauri 2 on
desktop and Android. TV hosts (Tizen/webOS) reuse the same frontend plus a
WASM build of the portable crates.

## Requirements

| For | Install |
|---|---|
| Frontend | Bun 1.3+ (https://bun.sh) |
| Desktop app | Rust 1.89+ (`rust-toolchain.toml` pins it) and the [Tauri Linux deps](https://tauri.app/start/prerequisites/) — on Debian/Ubuntu: `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev` |
| Android app | Java 21, Android SDK + NDK, `cargo tauri` CLI, `rustup target add aarch64-linux-android` |
| TV core | `rustup target add wasm32-unknown-unknown` |

One install covers the workspace:

```bash
bun install
```

## Test

```bash
bun run test          # JS unit tests (bun:test, no config)
bun run test:watch    # reruns on save
cargo test --workspace
bun run test:live     # hits real debrid APIs, opt-in, needs keys in .env
```

The `@/` alias resolves through `jsconfig.json`; `test/bun-register.js`
(preloaded automatically via `bunfig.toml`) stubs UI-only dependencies so app
modules import under the test runtime.

```
test/
├── unit/            fast, no network — run on every push
│   ├── debrid/      debrid services, availability, routing, rate limits,
│   │                episode picking, pack windowing, resume identity
│   └── playback/    subtitles, fonts, file matching, and the full
│                    DebridMetadata stream/seek/pacing pipeline against
│                    fixtures/episode.mkv over mocked range requests
├── live/            hits real APIs, opt-in only
├── fixtures/        episode.mkv — synthetic release; regenerate with
│                    tools/make-fixture.sh
└── tools/           manual diagnostics, not run by the suite
```

Rust tests live next to the code they test in `crates/*` (`cargo test`).

## Run (desktop)

```bash
bun run tauri:dev
```

Starts Vite on :5173 and the Tauri window against it. If graphics act up on
Linux (NVIDIA/Wayland), try `SHIRU_GRAPHICS=safe bun run tauri:dev`.

## Build (desktop)

```bash
bun run tauri:build
```

Builds the frontend into `dist/web` and a release `shiru-tauri` binary in
`target/release`. Installer packaging (`cargo tauri build`) uses
`hosts/tauri/tauri.conf.json`.

## Build (Android)

```bash
cargo tauri android build    # from hosts/tauri
```

Produces an APK/AAB from the same Rust core and frontend. Device adapters
(Media3 player, PiP, foreground service) are still in progress.

## Build (TV core)

```bash
./scripts/build-tv-core.sh
```

Builds the portable crates to WASM (`dist/tv-core`) for the Tizen/webOS hosts
in `hosts/tizen` and `hosts/webos`. Both TV hosts are scaffolds gated on real
hardware — see their READMEs.

## Layout

```
common/          Svelte frontend (presentation only)
crates/          shared Rust core: domain, core, debrid, torrent, media,
                 networking, storage, credentials, sources, platform-contracts,
                 wasm-bridge
hosts/tauri/     desktop + Android host (thin command adapters)
hosts/tizen/     Samsung TV host scaffold
hosts/webos/     LG TV host scaffold
extensions/      example source extension
test/            JS test suite
docs/migration/  architecture report, progress, parity checklist
```

The rule for new code: presentation goes in `common/`, everything else goes in
`crates/`, platform-specific glue goes in the host. `common/modules/bridge.js`
is the only file in the frontend allowed to touch a host API.
