# Dependency maintenance

Zero is a Flutter application, so both `pubspec.yaml` and `pubspec.lock` are
intentional. The manifest declares the direct packages the code and native
runners require. The committed lockfile records the exact hosted and transitive
versions, checksums, and local path packages used by a reproducible build.

The `https://pub.dev` entries in `pubspec.lock` are package source metadata, not
leftovers from Node, Tauri, or Rust. Do not hand-edit the lockfile.

## Routine update

Check dependencies monthly, before a release, and promptly when a relevant
security advisory is published:

```bash
flutter pub outdated
flutter pub upgrade --dry-run
```

For one package whose current constraint already allows the desired release:

```bash
flutter pub upgrade package_name --unlock-transitive
```

Use `flutter pub upgrade` without a package name only for a deliberate batch of
compatible updates. Review both manifest and lockfile changes:

```bash
git diff -- pubspec.yaml pubspec.lock
flutter pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build linux --release --no-pub
flutter build apk --release --split-per-abi --no-pub
```

Commit `pubspec.yaml` and `pubspec.lock` together whenever both change. CI uses
`--enforce-lockfile`, so a stale or missing resolution fails instead of being
silently regenerated.

## Major and native updates

Preview constraint-changing upgrades with:

```bash
flutter pub upgrade --major-versions --dry-run
```

Read each package changelog and update direct constraints intentionally. Prefer
one major or native-plugin family per change so regressions remain attributable.
For a Flutter SDK upgrade, update the CI `FLUTTER_VERSION` and Dart SDK bound in
the same change, then build on every supported target OS.

Treat these packages as native-risk changes even if their Dart APIs appear
unchanged:

- `media_kit`, `media_kit_video`, and `media_kit_libs_video`;
- `sqlite3` and its platform binaries;
- `flutter_secure_storage`;
- `path_provider` and `window_manager`.

The local `path:` entries for `media_kit` and `media_kit_video` are required
patches, not development links. Never replace them with hosted packages as part
of a general upgrade. Rebase each patch onto a reviewed upstream release,
retain the patch explanation in `pubspec.yaml`, and validate playback plus
process teardown on Linux before merging.

Automated update pull requests may be used as notifications, but native and
major upgrades must not be merged solely because version resolution and unit
tests pass.
