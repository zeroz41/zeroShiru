# CI & Releases

| Workflow | Trigger | Does |
|---|---|---|
| `ci.yml` | push / PR | unit tests + production webpack builds (electron, capacitor) |
| `release.yml` | `v*` tag push, or manual dispatch | runs CI, builds all platforms, drafts a GitHub Release |
| `issues.yml` | issues | bug report labeling |

Publishing is GitHub Releases only; upstream's R2/GitLab/Codeberg workflows
were removed. In-app updaters point at `zeroz41/zeroShiru`.

## Artifacts

- **Windows**: NSIS installer + portable
- **macOS**: universal DMG
- **Linux**: AppImage (x64). The `dir` target also builds the raw binary into
  `linux-unpacked/`, but a directory cannot be uploaded to a Release, so it is
  a local-build convenience only.
- **Android / TV**: `arm64-v8a` + `armeabi-v7a` APKs (armv7 = 32-bit TV boxes;
  same APK works on phone and TV)

Dropped from upstream: deb, flatpak, x86_64/universal APKs. Re-enable in
`electron/electron-builder.yml` / `capacitor/android/app/build.gradle` if needed.

## Tests in CI

- **Unit**: `pnpm test` — everything under `test/unit/`, picked up by glob, so
  new test files need no workflow change. Installed with `--ignore-scripts`
  (no native builds), so tests must stay pure JS.
- **Live API**: `pnpm test:live`, manual only (Actions → CI → Run workflow →
  tick "live tests"). Keys come from secrets `REAL_DEBRID_API_KEY` /
  `TORBOX_API_KEY`; **unset keys make those tests skip**, so the secrets are
  optional and personal keys need never live in the repo. Optional fixture
  vars: `RD_TEST_MAGNET`, `RD_TEST_PACK_MAGNET`, `RD_TEST_PACK_EPISODE`,
  `TORBOX_TEST_HASH`. Prefer running these locally
  ([BUILDING.md](../BUILDING.md#test)).

## Releasing

1. Bump `version` in `electron/package.json`. Plain semver (`6.8.1`) — the
   stable updater skips prerelease suffixes; tags containing `beta` are marked
   prerelease.
2. `git tag v6.8.1 && git push origin v6.8.1` — or Actions → Release → tick
   confirm. Tag must match the package version or the run fails.
3. Jobs upload to a **draft** release. Review, write notes, publish — the
   updater only sees it once published.

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

- Keep the `electronDownload` mirror in `electron-builder.yml` — it likely
  serves a codec-patched Electron; stock Electron may break playback.
- Fork app IDs are `com.github.zeroz41.zeroshiru` (desktop) and
  `watch.zeroshiru` (Android): installs live alongside upstream Shiru, and
  updates can't cross over from upstream installs.
