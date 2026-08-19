# Building zeroShiru

A Svelte frontend on a shared Rust core, hosted by Tauri 2 on desktop and
Android. The TV hosts (Tizen/webOS) reuse the same frontend with the portable
crates compiled to WebAssembly.

## Quick start

From the repository root:

```bash
make install    # fetch the frontend packages
make dev        # run the app
```

That is the whole loop. `make` on its own lists every target:

```
  make install        fetch the frontend packages
  make dev            run the desktop app against the dev server
  make build          production frontend into dist/web
  make bundle         installers for this OS (AppImage/deb, MSI/NSIS, DMG)
  make android        APK from the same core
  make tv             the shared core as WASM, for the TV hosts
  make test           everything that runs offline
  make test-js        JS unit tests
  make test-rust      Rust workspace tests
  make test-live      opt-in: debrid providers and playback against real accounts
  make test-torrent   opt-in: one real torrent through the engine and gateway
  make clean          drop build output (not the packages)
```

The targets find Bun and Cargo themselves, so they work even when neither is on
your `PATH` — which is the usual state after installing Bun under fish. To use
`bun` directly in a shell, add it once:

```fish
fish_add_path ~/.bun/bin              # fish
export PATH="$HOME/.bun/bin:$PATH"    # bash/zsh, in your profile
```

If graphics act up on Linux (a black window, or none at all), start once with
`SHIRU_GRAPHICS=safe make dev`, then pick a mode in Settings → Interface.

## Requirements

Everything needs Bun and Rust; the rest depends on what you are building.

| For | Install |
|---|---|
| Frontend | [Bun](https://bun.sh) 1.3+ |
| Any host | Rust 1.89+ (`rust-toolchain.toml` pins it) and `cargo install tauri-cli --locked` |
| Linux build | `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev patchelf` (Debian/Ubuntu names; see [Tauri prerequisites](https://tauri.app/start/prerequisites/) for other distros) |
| Windows build | Visual Studio Build Tools (MSVC + Windows SDK) and [WebView2](https://developer.microsoft.com/microsoft-edge/webview2/) — preinstalled on Windows 11 |
| macOS build | Xcode Command Line Tools; for universal binaries `rustup target add aarch64-apple-darwin x86_64-apple-darwin` |
| Android build | Java 21, Android SDK (API 36) + NDK 27, `ANDROID_HOME`/`NDK_HOME` set, `rustup target add aarch64-linux-android armv7-linux-androideabi` |
| TV core | `rustup target add wasm32-unknown-unknown` and `cargo install wasm-bindgen-cli` |
| Tizen package | [Tizen Studio CLI](https://developer.samsung.com/smarttv/develop/tools.html) (`tizen`) |
| webOS package | [webOS TV CLI](https://webostv.developer.lge.com/develop/tools/cli-installation) (`ares-package`) |

Node is **not** a requirement. Bun runs the tests, and the build goes through
`bun x --bun vite`, which keeps Vite on Bun's runtime instead of letting its
`#!/usr/bin/env node` shebang hand the build to `node`.

Desktop bundles are not cross-compiled: build each OS on that OS, or let CI do
it (see [docs/CI.md](docs/CI.md)).

## Test

```bash
make test          # JS + Rust, offline — what CI runs
make test-js
make test-rust
```

Most of the app is Rust, so most of the tests are: providers, availability,
routing, episode picking, pack windowing, watch keys, the torrent session and
the filename recognizer are all `cargo test`. The JS suite covers what is still
JS — the player, subtitles, fonts, file matching, the debrid routing policy and
the seam between the UI and the core.

```
frontend/test/
├── unit/            fast, no network — run on every push
│   ├── app/         settings, protocol routing, stores
│   ├── debrid/      routing policy, availability vocabulary, the host seam
│   └── playback/    subtitles, fonts, file matching, and the full
│                    DebridMetadata stream/seek/pacing pipeline against
│                    fixtures/episode.mkv over mocked range requests
├── live/            hits real APIs, opt-in only
├── fixtures/        episode.mkv — synthetic release; regenerate with
│                    tools/make-fixture.sh
└── tools/           live-link.js (a stream link for the live playback tests)
                     and manual diagnostics, not run by the suite
```

Rust tests live beside the code they test in `crates/*`; the live ones are
`#[ignore]`d, so `make test-rust` never touches the network.

### Opt-in suites

```bash
make test-live       # debrid providers and playback, against a real account
make test-torrent    # one real public torrent through the engine and gateway
```

Both read `.env` at the repository root (copy `.env.example`). A service with no
key skips its tests, so no key ever has to live in the repo. Run these
deliberately — the torrent one joins a swarm.

## Run and build (desktop)

```bash
make dev       # Vite on :5173 plus the Tauri window against it
make build     # production frontend into dist/web
make bundle    # frontend + installers for this OS
```

`make bundle` packages what `hosts/tauri/tauri.conf.json` lists under
`bundle.targets`:

| Host OS | Artifacts | Where |
|---|---|---|
| Linux | `.AppImage`, `.deb` | `target/release/bundle/{appimage,deb}/` |
| Windows | `.msi` (WiX), `-setup.exe` (NSIS) | `target/release/bundle/{msi,nsis}/` |
| macOS | `.app`, `.dmg` | `target/release/bundle/{macos,dmg}/` |

macOS universal (Apple silicon + Intel in one bundle):

```bash
cd hosts/tauri && cargo tauri build --target universal-apple-darwin
```

Its bundles land under `target/universal-apple-darwin/release/bundle/`.

Signing is not wired up: Linux and Windows artifacts are unsigned, and macOS
builds are ad-hoc signed unless `APPLE_CERTIFICATE` and friends are in the
environment. In-app updates stay inert until a signing keypair exists — see
[docs/CI.md](docs/CI.md#updater).

## Build (Android)

Phone and TV ship the same APK; `armeabi-v7a` covers 32-bit TV boxes.

```bash
make android                                             # arm64 APK
cd hosts/tauri && cargo tauri android build --apk --split-per-abi \
  --target aarch64 --target armv7                        # both ABIs
cd hosts/tauri && cargo tauri android build --aab        # Play Store bundle
```

Output: `hosts/tauri/gen/android/app/build/outputs/{apk,bundle}/release/`. The
Gradle project in `hosts/tauri/gen/android` is committed, so
`cargo tauri android init` is not needed — re-running it would overwrite local
edits. Release APKs come out unsigned; CI signs them from repository secrets.

Device adapters (Media3 player, PiP, foreground service, SAF) are still in
progress: the APK assembles and runs the shared core, but Android-native
playback integration is not there yet.

## Build (TV)

Both TV hosts are scaffolds gated on real hardware — read
[hosts/tizen/README.md](hosts/tizen/README.md) and
[hosts/webos/README.md](hosts/webos/README.md) before starting either port.

```bash
make build     # frontend  -> dist/web
make tv        # Rust core -> dist/tv-core (wasm32 + wasm-bindgen glue)
```

Both hosts then assemble those two outputs with their own adapters:

| Target | Package with | Produces |
|---|---|---|
| Samsung Tizen | `tizen build-web && tizen package -t wgt -s <profile>` in the assembled `hosts/tizen` tree | signed `.wgt` |
| LG webOS | `ares-package <assembled hosts/webos tree>` | `.ipk` |

The WASM build must stay on baseline WebAssembly (no SIMD, no threads) so
2020-era TVs can run it.

## Version and release

`hosts/tauri/tauri.conf.json` holds the version tags are checked against.
Releasing is a tag push; see [docs/CI.md](docs/CI.md).

## Layout

```
frontend/        everything JS: the workspace root, its lockfile and its packages
  common/        Svelte frontend (presentation only)
  extensions/    example source extension
  test/          JS test suite
crates/          shared Rust core: domain, core, debrid, torrent, media,
                 networking, storage, credentials, sources, platform-contracts,
                 wasm-bridge
hosts/tauri/     desktop + Android host (thin command adapters)
hosts/tizen/     Samsung TV host scaffold
hosts/webos/     LG TV host scaffold
scripts/         what the Makefile targets run
docs/migration/  architecture report, progress, parity checklist
```

Packages install to `frontend/.deps`, with `frontend/node_modules` as a symlink
into it. The link has to carry that name even though nothing here runs on Node:
Bun, Vite, esbuild and Rollup all resolve bare imports by walking up for a path
segment called `node_modules`, and Vite's CommonJS interop only applies to files
under one. `scripts/deps-dir.sh` sets it up after every install.

The rule for new code: presentation goes in `frontend/common/`, everything else
goes in `crates/`, platform-specific glue goes in the host.
`frontend/common/modules/bridge.js` is the only file in the frontend allowed to
touch a host API.
