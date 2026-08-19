# CI & Releases

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push / PR | JS unit tests, production frontend build, `cargo test --workspace`, wasm32 core build |
| `release.yml` | `v*` tag push, or manual dispatch | runs CI, builds every platform, drafts a GitHub Release |
| `issues.yml` | issues | bug report labeling |

Publishing is GitHub Releases only; upstream's R2/GitLab/Codeberg workflows
were removed. In-app updaters point at `zeroz41/zeroShiru`.

The JS workspace is `frontend/`, so every `bun` step in CI runs with
`working-directory: frontend`; `cargo` steps run from the repository root.

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

In-app updates are built and wired: the app checks on a timer, downloads, and
restarts into the new version. What is missing is a **signing keypair**, and it
has to be missing until you make one, because Tauri only installs an update
whose signature matches the public key compiled into the app. That is the whole
security model: without it, anyone who could serve you a file could serve you a
program. Until the key exists, a check answers `unconfigured` and the app says
nothing — an update prompt that can never install is worse than no prompt.

To turn updates on, once:

```bash
cargo tauri signer generate -w ~/.tauri/zeroshiru.key
```

That writes two things: a **private key** (`~/.tauri/zeroshiru.key`) that signs
releases, and a **public key** printed to the terminal that verifies them. Back
the private key up somewhere private and never commit it — lose it and existing
installs can never be updated again, since a new key cannot sign for the old one.

Then, in the repository settings:

```bash
gh variable set TAURI_PUBKEY --body "<the public key it printed>"
gh secret set TAURI_SIGNING_PRIVATE_KEY < ~/.tauri/zeroshiru.key
gh secret set TAURI_SIGNING_PRIVATE_KEY_PASSWORD   # paste when prompted
```

`TAURI_PUBKEY` is the switch: with it set, release builds compile the key in,
emit signed updater artifacts, and the `update-manifest` job publishes the
`latest.json` the app reads. Without it, releases build exactly as they do now
and simply are not self-updating.

Channels: the app follows `latest.json` on the newest non-prerelease for stable,
and `latest.json` on a release tagged `nightly` for the nightly channel — GitHub's
"latest release" pointer deliberately skips prereleases, so nightlies need their
own fixed tag.

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
