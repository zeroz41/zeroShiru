# Building zeroShiru

## Requirements

- Node.js 24 + pnpm 10 (`corepack enable`)
- Android: Java 21 (JDK), Android SDK + ADB, Docker (one-time native module build)
- Windows desktop builds: Visual Studio 2022 build tools
- macOS desktop builds: Xcode command line tools, `pip3 install setuptools`

## Run (development)

Desktop, with hot reload:

```bash
cd electron
pnpm install
pnpm start
```

Android, on an ADB-connected device:

```bash
cd capacitor
pnpm install
pnpm build:native     # first time only (Windows: pnpm build:native-win)
pnpm dev:start
```

## Desktop builds

All from `electron/` after `pnpm install`. Artifacts land in `electron/dist/`.
Each OS builds its own targets — no cross-building (CI's release matrix runs
one job per OS for exactly this reason).

```bash
pnpm build                                            # all targets for the current OS
```

Or per target:

```bash
pnpm run web:build && pnpm exec electron-builder --win             # Windows: NSIS installer + portable
pnpm run web:build && pnpm exec electron-builder --mac             # macOS: universal DMG
pnpm run web:build && pnpm exec electron-builder --linux AppImage  # Linux: AppImage (x64)
```

## Android / Android TV builds

```bash
cd capacitor
pnpm install
pnpm build:app                            # webpack + native + capacitor sync
cd android && ./gradlew assembleRelease
```

Outputs two unsigned APKs in `android/app/build/outputs/apk/release/`:
`arm64-v8a` (phones, tablets, modern TVs) and `armeabi-v7a` (32-bit TV boxes:
Chromecast with Google TV, Fire TV). There is no separate TV build — the
manifest declares leanback support, the same APK runs on both.

To install, sign with your keystore (see [docs/CI.md](docs/CI.md) for
generating one; CI signs release builds automatically):

```bash
apksigner sign --ks zeroshiru.jks app-arm64-v8a-release-unsigned.apk
```

## Test

Unit tests (plain `node:test`, from repo root):

```bash
pnpm install
node --import ./test/register.js --test test/unit/*.test.js
```

Live API tests hit real debrid services. No key in the environment → that
service's tests skip:

```bash
REAL_DEBRID_API_KEY=xxx TORBOX_API_KEY=xxx \
  node --import ./test/register.js --test --test-concurrency=1 test/live/*.test.js
```

CI runs the unit tests and production builds on every push — see
[docs/CI.md](docs/CI.md).
