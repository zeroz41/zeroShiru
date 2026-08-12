# Building zeroShiru

## Requirements

Everyone needs Node.js 24+ and pnpm 10 (`corepack enable`). Running the tests
needs nothing else.

Building the app compiles native modules, so you also need a toolchain for the
machine you are building **on**:

| Building on | Also install |
|---|---|
| Linux | a C/C++ toolchain and Python 3 — `apt install build-essential python3` (Debian/Ubuntu) or `pacman -S base-devel python` (Arch) |
| Windows | Visual Studio 2022 with the "Desktop development with C++" workload |
| macOS | Xcode command line tools (`xcode-select --install`), then `pip3 install setuptools` |

Building for Android additionally needs, on any host:

- Java 21 (JDK)
- Android SDK 36 + ADB (Android Studio installs both)
- Docker — used once to build the bundled Node runtime

One install covers the whole workspace:

```bash
pnpm install
```

## Test

One command, from the repo root:

```bash
pnpm test          # all unit tests
pnpm test:watch    # reruns on save
```

Tests are plain [`node:test`](https://nodejs.org/api/test.html) — no framework
to learn, no config to touch. `test/register.js` maps the app's webpack
aliases (`@/`, `@client/`) onto real paths so app modules import under plain
Node.

### Where tests live

```
test/
├── unit/            fast, no network — run on every push
│   ├── debrid/      debrid services, availability, routing, rate limits
│   └── playback/    subtitles, fonts, file matching
├── live/            hits real APIs, opt-in only
│   ├── debrid/
│   └── playback/
└── tools/           manual diagnostics, not run by the suite
```

Add a file ending in `.test.js` anywhere under `unit/` and it runs — including
in a new subfolder, so `test/unit/torrent/` needs no setup beyond creating it.

### Live tests and API keys

Live tests talk to real debrid accounts, so they are never part of `pnpm test`.
**A service with no key configured skips its tests**, so this is safe to run
with nothing set up — you get a list of skips, not failures:

```bash
pnpm test:live
```

To actually exercise them, copy `.env.example` to `.env` and fill in what you
have. `.env` is gitignored and read automatically:

```bash
cp .env.example .env
$EDITOR .env
pnpm test:live
```

Or pass them per-run, if you would rather not keep keys on disk:

```bash
REAL_DEBRID_API_KEY=xxx pnpm test:live          # bash / zsh
env REAL_DEBRID_API_KEY=xxx pnpm test:live      # fish
```

| Variable | Needed for |
|---|---|
| `REAL_DEBRID_API_KEY` | Real-Debrid tests — key from [real-debrid.com/apitoken](https://real-debrid.com/apitoken) |
| `TORBOX_API_KEY` | TorBox tests — key from your TorBox account settings |
| `RD_TEST_MAGNET` | resolve/playback tests: a magnet or hash already cached on the account |
| `RD_TEST_PACK_MAGNET`, `RD_TEST_PACK_EPISODE` | season-pack episode picking, e.g. a pack hash and `25` |
| `TORBOX_TEST_HASH` | TorBox cache-check test: an info hash TorBox reports as cached |

Live tests are deliberately non-destructive — they only resolve releases
already on the account and assert they don't add duplicates. They do consume
API quota, so they stay opt-in.

### Keeping keys out of commits

`.env` and `.env.*` are gitignored at every level, and no key is ever written
into a test file. For a second line of defense, enable the repo's pre-commit
hook once — it refuses any commit carrying an API key or an `.env` file:

```bash
git config core.hooksPath .githooks
```

CI runs `pnpm test` plus both production builds on every push, and the live
suite only on manual request ([docs/CI.md](docs/CI.md)).

## Run in development

Desktop, with hot reload:

```bash
cd electron
pnpm start
```

Android, on an ADB-connected device:

```bash
cd capacitor
pnpm build:native     # first time only, see below
pnpm dev:start
```

`build:native` builds the bundled Node runtime inside Docker and only has to
run once. Which script you use depends on the machine you are sitting at, not
on the device you are targeting:

```bash
pnpm build:native       # Linux and macOS hosts
pnpm build:native-win   # Windows hosts (Docker via WSL)
```

If the device or SDK isn't picked up, `pnpm exec cap doctor` says what's missing.

## Desktop builds

Each OS builds its own targets — there is no cross-building, which is why CI
runs one job per OS.

```bash
cd electron
pnpm build            # every target for the OS you are on
```

Or one target at a time:

```bash
pnpm run web:build && pnpm exec electron-builder --win
pnpm run web:build && pnpm exec electron-builder --mac
pnpm run web:build && pnpm exec electron-builder --linux AppImage
```

Everything lands in `electron/dist/`. `X.X.X` is the `version` from
`electron/package.json`:

| Built on | File | What it is |
|---|---|---|
| Windows | `win-Shiru-vX.X.X-installer.exe` | NSIS installer, can pick install dir |
| Windows | `win-Shiru-vX.X.X-portable.exe` | run directly, no install |
| macOS | `mac-Shiru-vX.X.X.dmg` | universal (Apple Silicon + Intel) |
| macOS | `mac-Shiru-vX.X.X.zip` | same app zipped, used by the auto-updater |
| Linux | `linux-Shiru-vX.X.X.AppImage` | `chmod +x` and run — needs FUSE (`libfuse2` on Debian/Ubuntu, `fuse2` on Arch), or run it with `--appimage-extract-and-run` |

## Android / Android TV builds

```bash
cd capacitor
pnpm build:app                            # webpack + native + capacitor sync
cd android && ./gradlew assembleRelease
```

Output in `capacitor/android/app/build/outputs/apk/release/`:

| File | Runs on |
|---|---|
| `app-arm64-v8a-release-unsigned.apk` | phones, tablets, modern Android TV |
| `app-armeabi-v7a-release-unsigned.apk` | 32-bit TV boxes (Chromecast with Google TV, Fire TV) |

Minimum Android version is 7.0 (API 24), phone and TV alike.

Gradle's output is unsigned; Android refuses to install it as-is. Sign it with
your own keystore (CI does this automatically for releases — see
[docs/CI.md](docs/CI.md) for generating one):

```bash
apksigner sign --ks zeroshiru.jks --out zeroShiru-arm64.apk app-arm64-v8a-release-unsigned.apk
adb install zeroShiru-arm64.apk
```

Released APKs are named `android-Shiru-vX.X.X-arm64-v8a.apk` /
`android-Shiru-vX.X.X-armeabi-v7a.apk`; the in-app updater looks them up by
that exact name.
