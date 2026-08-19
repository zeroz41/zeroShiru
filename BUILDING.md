# Building zeroShiru

A Svelte frontend on a shared Rust core, hosted by Tauri 2 on desktop and
Android. The TV hosts (Tizen/webOS) reuse the same frontend with the portable
crates compiled to WebAssembly.

Two workspaces, two toolchains:

| Workspace | Root | Tool | Commands run from |
|---|---|---|---|
| JS (Svelte frontend, JS tests) | `frontend/` | Bun | `frontend/` |
| Rust (shared core, hosts) | repository root | Cargo | repository root |

Every command below says which directory it belongs in. Nothing wraps them.

## Prerequisites

Bun and Rust are needed for everything; the rest depends on the target.

| For | Install |
|---|---|
| Frontend | [Bun](https://bun.sh) 1.3+ |
| Any host | Rust 1.89+ (pinned by `rust-toolchain.toml`) and `cargo install tauri-cli --locked` |
| Linux desktop | `libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev librsvg2-dev patchelf` (Debian/Ubuntu names; see [Tauri prerequisites](https://tauri.app/start/prerequisites/) for other distros) |
| Windows desktop | Visual Studio Build Tools (MSVC + Windows SDK) and [WebView2](https://developer.microsoft.com/microsoft-edge/webview2/) — preinstalled on Windows 11 |
| macOS desktop | Xcode Command Line Tools; for universal binaries `rustup target add aarch64-apple-darwin x86_64-apple-darwin` |
| Android | Java 21, Android SDK (API 36) + NDK 27, `ANDROID_HOME`/`NDK_HOME` set, `rustup target add aarch64-linux-android armv7-linux-androideabi` |
| TV core | `rustup target add wasm32-unknown-unknown` and `cargo install wasm-bindgen-cli` |
| Tizen package | [Tizen Studio CLI](https://developer.samsung.com/smarttv/develop/tools.html) (`tizen`) |
| webOS package | [webOS TV CLI](https://webostv.developer.lge.com/develop/tools/cli-installation) (`ares-package`) |

Bun's installer drops it in `~/.bun/bin` without editing your shell config, so
put it on `PATH` once:

```fish
fish_add_path ~/.bun/bin              # fish
export PATH="$HOME/.bun/bin:$PATH"    # bash/zsh, in your profile
```

Node is **not** a requirement. Bun runs the tests, and the build goes through
`bun x --bun vite`, which keeps Vite on Bun's runtime instead of letting its
`#!/usr/bin/env node` shebang hand the build to `node`.

## Install

Once, and again whenever `frontend/bun.lock` changes:

```bash
cd frontend
bun install
```

Packages land in `frontend/.deps`, with `frontend/node_modules` as a symlink
into it — see [Layout](#layout) for why that name has to exist. The
`postinstall` hook (`scripts/deps-dir.sh`) sets the link up for you.

Cargo needs no install step; it fetches crates on first build.

## Run (development)

This is the dev loop. For launching a *built* artifact — the binary, an
AppImage, a `.deb`, an APK — see the "Run what you built" subsection at the end
of each build section below.

```bash
cd frontend
bun run tauri:dev
```

That starts Vite on `:5173` and the Tauri window pointed at it, with hot reload
on the frontend. Ctrl-C stops both — the script traps the signal and kills the
dev server with the window. It is `scripts/dev.sh` if you want to read it.

To run the built desktop binary directly, without the dev server:

```bash
cd frontend && bun run build     # frontend must exist first
cd .. && cargo run -p shiru-tauri --features custom-protocol
```

The feature flag matters: without it Cargo builds the *dev* binary, which
renders the Vite dev server on `:5173` — a window saying "Could not connect to
localhost" if no dev server is running. `custom-protocol` embeds `dist/web`
instead; it is what `cargo tauri build` turns on for bundles.

If graphics act up on Linux (a black window, or none at all), start once with
`SHIRU_GRAPHICS=safe bun run tauri:dev`, then pick a mode in Settings →
Interface.

## Test

```bash
cd frontend && bun run test      # JS unit tests
cd .. && cargo test --workspace  # Rust tests
```

Together those are what CI runs. Both are offline — the live tests are
`#[ignore]`d on the Rust side and live in a separate directory on the JS side,
so neither command touches the network.

Most of the app is Rust, so most of the tests are: providers, availability,
routing, episode picking, pack windowing, watch keys, the torrent session and
the filename recognizer are all `cargo test`, living beside the code they test
in `crates/*`. The JS suite covers what is still JS — the player, subtitles,
fonts, file matching, the debrid routing policy and the seam between the UI and
the core.

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

Useful variants:

```bash
cd frontend
bun run test:watch                          # re-run JS tests on change
bun test --preload ./test/bun-register.js test/unit/playback   # one directory

cd ..
cargo test -p shiru-debrid                  # one crate
cargo test --workspace routing              # tests matching a name
```

### Opt-in suites

These hit the network and real accounts, so run them deliberately — the torrent
one joins a swarm.

```bash
cd frontend && bun run test:live   # debrid providers and playback, real account
cd .. && cargo test -p shiru-debrid --features native --test live -- --ignored --nocapture
cargo run -p shiru-torrent --features native --example smoke   # one real torrent
```

Both live suites read `.env` at the repository root — copy `.env.example` to
`.env` and fill in what you have. Every key is optional: a service with no key
skips its tests, so no key ever has to live in the repo.

## Build: desktop

Build the app and run it — three commands from the repository root:

```bash
cd frontend && bun run build                     # 1. frontend -> dist/web
cd .. && cargo build --release -p shiru-tauri --features custom-protocol   # 2. the app
./target/release/shiru-tauri                     # 3. run it
```

Step 3 opens the app. That is the whole loop: the binary is self-contained, so
there is nothing to install and nothing else to run. On Windows step 3 is
`.\target\release\shiru-tauri.exe`.

You need the rest of this section only if you want an **installer** — an
AppImage, `.deb`, `.msi` or `.dmg` to hand to someone else.

### Installers

`cargo tauri build` does **not** build the frontend (`beforeBuildCommand` is
empty in `hosts/tauri/tauri.conf.json`, so the two steps stay independently
runnable). Build the frontend first, always.

```bash
cd frontend
bun run build                     # -> dist/web
cd ../hosts/tauri
cargo tauri build                 # -> installers for this OS
```

Or as one command, which is the two above plus, on Linux, two workarounds:

```bash
cd frontend && bun run tauri:bundle
```

Those workarounds live in `scripts/bundle.sh` and are needed because Tauri
builds the AppImage with linuxdeploy, which is old enough to fall over on a
current Linux userland. It strips using the binutils inside its own AppImage,
which predates `DT_RELR` and so rejects every library a current toolchain
produces (`unknown type [0x13] section .relr.dyn`), and its GTK plugin locates
libraries with an unbounded `find` over the pkg-config libdir, so any vendored
copy sitting in a subdirectory of `/usr/lib` — VMware ships a `libgobject` that
still wants `libffi.so.6` — shadows the real one and fails to deploy. The
script sets `NO_STRIP` and bounds that `find` to the libdir itself, patching
the plugin where Tauri caches it (`~/.cache/tauri`). Running `cargo tauri
build` by hand on Linux hits both.

Artifacts, per `bundle.targets` in `hosts/tauri/tauri.conf.json`:

| Host OS | Artifacts | Where |
|---|---|---|
| Linux | `.AppImage`, `.deb` | `target/release/bundle/{appimage,deb}/` |
| Windows | `.msi` (WiX), `-setup.exe` (NSIS) | `target/release/bundle/{msi,nsis}/` |
| macOS | `.app`, `.dmg` | `target/release/bundle/{macos,dmg}/` |

### Installing and running those

The bundled artifacts carry the version from `hosts/tauri/tauri.conf.json`
(`6.8.0` at the time of writing), so substitute yours in the names below.

```bash
# Linux — AppImage: no install, just make it executable
chmod +x target/release/bundle/appimage/zeroShiru_6.8.0_amd64.AppImage
./target/release/bundle/appimage/zeroShiru_6.8.0_amd64.AppImage

# Linux — deb: installs to /usr/bin/zeroShiru and the application menu
sudo apt install ./target/release/bundle/deb/zeroShiru_6.8.0_amd64.deb
zeroShiru
sudo apt remove zeroshiru                 # to undo
```

```bash
# macOS — run the app bundle in place, or open the disk image to install it
open target/release/bundle/macos/zeroShiru.app
open target/release/bundle/dmg/zeroShiru_6.8.0_aarch64.dmg
```

On Windows, run the `.msi` or `-setup.exe` from
`target\release\bundle\{msi,nsis}\` and launch zeroShiru from the Start menu.

Because nothing is signed, the OS will object on first launch: macOS needs
right-click → Open (or `xattr -d com.apple.quarantine` on the `.app`), and
Windows SmartScreen needs "More info" → "Run anyway".

macOS universal (Apple silicon + Intel in one bundle), from `hosts/tauri`:

```bash
cargo tauri build --target universal-apple-darwin
```

Its bundles land under `target/universal-apple-darwin/release/bundle/`.

Desktop bundles are **not** cross-compiled: build each OS on that OS, or let CI
do it (see [docs/CI.md](docs/CI.md)).

Signing is not wired up. Linux and Windows artifacts are unsigned, and macOS
builds are ad-hoc signed unless `APPLE_CERTIFICATE` and friends are in the
environment. In-app updates stay inert until a signing keypair exists — see
[docs/CI.md](docs/CI.md#updater).

## Build: Android

Phone and TV boxes ship the same APK; `armeabi-v7a` covers 32-bit TV hardware.

Build it and run it on a real device — plug the phone in with USB debugging on,
confirm `adb devices` lists it, then two commands from the repository root:

```bash
cd frontend && bun run build                     # 1. frontend -> dist/web
cd ../hosts/tauri && cargo tauri android dev     # 2. build, install, launch
```

Step 2 does everything: it builds a debug APK, installs it on the connected
device or emulator, and starts the app, with the frontend hot-reloading against
your machine. To watch the Rust core's logs while it runs:

```bash
adb logcat -s RustStdoutStderr
```

You need the rest of this section only if you want a **release APK** to
distribute.

### Release APK

```bash
cd frontend
bun run build
cd ../hosts/tauri
cargo tauri android build --apk                  # arm64 APK
```

Or the one-command equivalent:

```bash
cd frontend && bun run android:build
```

Other shapes, from `hosts/tauri`:

```bash
cargo tauri android build --apk --split-per-abi --target aarch64 --target armv7
cargo tauri android build --aab                  # Play Store bundle
```

Output: `hosts/tauri/gen/android/app/build/outputs/{apk,bundle}/release/`.

### Installing and running a release APK

Release APKs come out **unsigned**, and Android refuses to install an unsigned
package — `adb install` fails on the artifact above until you sign it:

```bash
apksigner sign --ks <your.keystore> \
  hosts/tauri/gen/android/app/build/outputs/apk/release/app-release-unsigned.apk
adb install -r hosts/tauri/gen/android/app/build/outputs/apk/release/app-release-unsigned.apk
adb shell am start -n watch.zeroshiru.app/.MainActivity
```

The Gradle project in `hosts/tauri/gen/android` is committed, so
`cargo tauri android init` is **not** needed — re-running it overwrites local
edits. Release APKs come out unsigned; CI signs them from repository secrets.

Device adapters (Media3 player, PiP, foreground service, SAF) are still in
progress: the APK assembles and runs the shared core, but Android-native
playback integration is not there yet.

## Build: TV (Tizen / webOS)

**There is nothing runnable here yet.** Both TV hosts are scaffolds: you can
build the two inputs they need, but neither assembles into an installable
package today, so there is no app to launch on a TV. Both are gated on the
hardware verification spikes in [hosts/tizen/README.md](hosts/tizen/README.md)
and [hosts/webos/README.md](hosts/webos/README.md) — read those before starting
either port.

What you *can* build is the two outputs the hosts consume: the same frontend as
every other host, and the shared core compiled to WebAssembly instead of linked
as a native binary.

```bash
cd frontend
bun run build                     # frontend  -> dist/web
bun run tv:core                   # Rust core -> dist/tv-core
```

`tv:core` is `scripts/build-tv-core.sh`; run it directly from the repository
root if you prefer:

```bash
./scripts/build-tv-core.sh
```

It builds `shiru-wasm-bridge` for `wasm32-unknown-unknown` and runs
`wasm-bindgen --target web` over the result, leaving `shiru-core_bg.wasm` plus
its JS glue in `dist/tv-core/`.

Each host then assembles those two outputs with its own adapters:

| Target | Package with | Produces |
|---|---|---|
| Samsung Tizen | `tizen build-web && tizen package -t wgt -s <profile>` in the assembled `hosts/tizen` tree | signed `.wgt` |
| LG webOS | `ares-package <assembled hosts/webos tree>` | `.ipk` |

The WASM build must stay on baseline WebAssembly (no SIMD, no threads) so
2020-era TVs can run it.

### Installing and running on a TV (once a host exists)

Once a host does assemble into a package, the vendor CLIs install and launch it
on a TV in developer mode:

```bash
# Samsung Tizen — pair with the TV first via the Device Manager in Tizen Studio
tizen install -n zeroShiru.wgt -t <target-name>
tizen run -p watch.zeroshiru.app -t <target-name>
```

```bash
# LG webOS — register the TV once with `ares-setup-device`
ares-install --device <device-name> zeroShiru.ipk
ares-launch --device <device-name> watch.zeroshiru.app
ares-inspect --device <device-name> --app watch.zeroshiru.app   # remote devtools
```

## Clean

```bash
rm -rf dist/web dist/tv-core      # build output
cargo clean                       # Rust target/ (large; forces a full rebuild)
rm -rf frontend/.deps             # installed packages; re-run bun install after
```

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
scripts/         dev.sh, bundle.sh, build-tv-core.sh, deps-dir.sh
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
