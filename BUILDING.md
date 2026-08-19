# Building zeroShiru

The app is a Svelte frontend on a shared Rust core, hosted by Tauri 2 on
desktop and Android. TV hosts (Tizen/webOS) reuse the same frontend plus a
WASM build of the portable crates.

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

Desktop bundles are **not** cross-compiled: build each OS on that OS (or in
CI, which does exactly that — see [docs/CI.md](docs/CI.md)).

One install covers the JS workspace:

```bash
bun install
```

Packages land in `.deps/`, with `node_modules` as a symlink into it — the
resolvers in Bun, Vite, esbuild and Rollup all insist on that exact name, and
Vite's CommonJS interop only applies to files under one, so the link has to
exist even though nothing here runs on Node. `scripts/deps-dir.sh` sets it up
after every install.

## Test

```bash
bun run test          # JS unit tests (bun:test, no config)
bun run test:watch    # reruns on save
bun run test:rust     # cargo test --workspace
```

Those three run offline and are what CI runs. Everything below is opt-in and
talks to the real world.

```bash
bun run test:rust:live   # debrid providers against a real account
bun run test:live        # renderer playback against a real stream link
bun run test:torrent     # one real torrent through the engine and gateway
```

Most of the app is Rust, so most of the tests are: providers, availability,
routing, episode picking, pack windowing, watch keys, the torrent session and
the filename recognizer are all `cargo test`. The JS suite covers what is still
JS — the player, subtitles, fonts, file matching and the debrid routing policy.

```
test/
├── unit/            fast, no network — run on every push
│   ├── app/         settings, protocol routing, stores
│   ├── debrid/      routing policy and availability vocabulary
│   └── playback/    subtitles, fonts, file matching, and the full
│                    DebridMetadata stream/seek/pacing pipeline against
│                    fixtures/episode.mkv over mocked range requests
├── live/            hits real APIs, opt-in only
├── fixtures/        episode.mkv — synthetic release; regenerate with
│                    tools/make-fixture.sh
└── tools/           live-link.js (a stream link for the live playback tests)
                     and manual diagnostics, not run by the suite
```

Live tests read `.env` (copy `.env.example`); a service with no key skips its
tests, so no key ever has to live in the repo. The Rust live tests read the
same file. The torrent smoke test downloads a well-seeded public torrent and
reads its first bytes through the loopback gateway — run it deliberately, not
on a schedule.

Rust tests live next to the code they test in `crates/*`; the live ones are
`#[ignore]`d, so `cargo test --workspace` never touches the network.

## Run (desktop)

```bash
bun run tauri:dev
```

Starts Vite on :5173 and the Tauri window against it. If graphics act up on
Linux (NVIDIA/Wayland), try `SHIRU_GRAPHICS=safe bun run tauri:dev`.

## Build (desktop)

```bash
bun run tauri:build     # frontend + release binary, no installers
bun run tauri:bundle    # frontend + installers for the current OS
```

`tauri:build` puts the frontend in `dist/web` and a `shiru-tauri` binary in
`target/release` — enough to run the app locally. `tauri:bundle` additionally
runs `cargo tauri build` from `hosts/tauri`, which packages what
`hosts/tauri/tauri.conf.json` lists under `bundle.targets`:

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

Signing/notarization is not wired up: Linux and Windows artifacts are
unsigned, and macOS builds are ad-hoc signed unless `APPLE_CERTIFICATE` and
friends are set in the environment. The Tauri updater is likewise inert until
a signing keypair exists — see [docs/CI.md](docs/CI.md#updater).

## Build (Android)

Phone and TV ship the same APK; `armeabi-v7a` covers 32-bit TV boxes.

```bash
bun run android:build                                    # arm64 APK
cd hosts/tauri && cargo tauri android build --apk --split-per-abi \
  --target aarch64 --target armv7                        # both ABIs
cd hosts/tauri && cargo tauri android build --aab        # Play Store bundle
```

Output: `hosts/tauri/gen/android/app/build/outputs/{apk,bundle}/release/`.
The Gradle project in `hosts/tauri/gen/android` is committed, so
`cargo tauri android init` is not needed — re-running it would overwrite local
edits. Release APKs come out unsigned; CI signs them from repository secrets.

Device adapters (Media3 player, PiP, foreground service, SAF) are still in
progress — the APK assembles and runs the shared core, but Android-native
playback integration is not there yet.

## Build (TV)

The TV hosts are scaffolds gated on real hardware — see
[hosts/tizen/README.md](hosts/tizen/README.md) and
[hosts/webos/README.md](hosts/webos/README.md) before starting either port.

```bash
bun run build       # frontend  -> dist/web
bun run tv:core     # Rust core -> dist/tv-core (wasm32 + wasm-bindgen glue)
```

Both hosts then assemble the same two outputs with their own adapters:

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
