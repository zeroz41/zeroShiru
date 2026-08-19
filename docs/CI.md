# CI & Releases

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push / PR | JS unit tests, production frontend build, `cargo test --workspace`, wasm32 core build |
| `release.yml` | `v*` tag push, or manual dispatch | runs CI, builds every platform, drafts a GitHub Release |
| `issues.yml` | issues | bug report labeling |

Publishing is GitHub Releases only; upstream's R2/GitLab/Codeberg workflows
were removed. In-app updaters point at `zeroz41/zeroShiru`.

Nothing in CI uses npm, node or pnpm: Bun runs the JS side, Cargo runs the Rust
side, and desktop/Android packaging goes through the Tauri CLI.

## Artifacts

Built on the OS they target — desktop bundles are not cross-compiled.

- **Linux** (`ubuntu-22.04`): AppImage + deb, x64. Built on 22.04 rather than
  the newest image because an AppImage inherits the builder's glibc.
- **Windows**: MSI (WiX) + NSIS `-setup.exe`
- **macOS**: universal DMG (`--target universal-apple-darwin`)
- **Android / TV**: `arm64-v8a` + `armeabi-v7a` APKs (armv7 = 32-bit TV boxes;
  the same APK serves phone and Android TV)

Bundle targets live in `hosts/tauri/tauri.conf.json` under `bundle.targets`;
adding one there is enough to build it locally, but `release.yml` also needs
the new glob in its `matrix.bundles` before it reaches a release.

Not built yet: Flatpak, RPM, Play Store AAB, Tizen `.wgt`, webOS `.ipk`. The TV
packages are blocked on the hardware gates in `hosts/{tizen,webos}/README.md`.

## Tests in CI

- **Unit**: `bun run test` — everything under `test/unit/`, picked up by glob,
  so new test files need no workflow change. Installed with `--ignore-scripts`
  (no native builds), so tests must stay pure JS.
- **Rust**: `cargo test --workspace --locked`, plus a wasm32 build of
  `shiru-wasm-bridge` so the TV core cannot silently stop compiling. The live
  Rust tests are `#[ignore]`d, so this never touches the network.
- **Live API**: `bun run test:live` (renderer playback) and
  `bun run test:rust:live` (debrid providers), manual only (Actions → CI → Run
  workflow → tick "live tests"). Keys come from secrets `REAL_DEBRID_API_KEY` /
  `TORBOX_API_KEY`; **unset keys make those tests skip**, so the secrets are
  optional and personal keys need never live in the repo. Optional fixture
  vars: `TORBOX_TEST_HASH`, `TB_TEST_PACK_HASH`, `TB_TEST_PACK_EPISODE`,
  `RD_TEST_MAGNET`. Prefer running these locally
  ([BUILDING.md](../BUILDING.md#test)).
- **Torrent**: `bun run test:torrent` puts one real public torrent through the
  engine and the loopback gateway. Manual only, never in CI — it joins a swarm.

## Releasing

1. Bump `version` in `hosts/tauri/tauri.conf.json` (and
   `hosts/tauri/Cargo.toml`, which carries the same number). Plain semver
   (`6.8.1`) — the stable updater skips prerelease suffixes; tags containing
   `beta` are marked prerelease.
2. `git tag v6.8.1 && git push origin v6.8.1` — or Actions → Release → tick
   confirm. Tag must match the config version or the run fails.
3. Jobs upload to a **draft** release. Review, write notes, publish — the
   updater only sees it once published.

## Updater

The Tauri updater is not enabled yet: it needs a signing keypair, which is a
release-owner decision. To turn it on, once:

```bash
cargo tauri signer generate -w ~/.tauri/zeroshiru.key   # back this up privately
```

Then add the public key to `hosts/tauri/tauri.conf.json`
(`plugins.updater.pubkey` plus an endpoint), and set `TAURI_SIGNING_PRIVATE_KEY`
/ `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` as Actions secrets so release builds
produce signatures. Until then the bridge's update ops are noops.

## Android signing (one-time)

Actions secrets are encrypted, masked in logs, and unavailable to fork PRs.
Generate a keystore, back up the `.jks` privately (lose it and existing
installs can't update), never commit it:

```bash
keytool -genkeypair -v -keystore zeroshiru.jks -alias zeroshiru \
  -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 zeroshiru.jks | gh secret set SIGNING_KEY
gh secret set ALIAS --body "zeroshiru"
gh secret set KEY_STORE_PASSWORD   # paste when prompted
gh secret set KEY_PASSWORD
```

Desktop jobs need no secrets (built-in `GITHUB_TOKEN`).

## Gotchas

- App IDs are `watch.zeroshiru.app` (desktop + Android) and
  `watch.zeroshiru.tv` (webOS): installs live alongside upstream Shiru, and
  updates can't cross over from an upstream install.
- The Android Gradle project (`hosts/tauri/gen/android`) is committed and
  hand-edited. Do not run `cargo tauri android init` — it regenerates and
  overwrites it.
- Desktop artifacts are unsigned; macOS builds are ad-hoc signed unless Apple
  credentials are present in the environment.
