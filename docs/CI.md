# Continuous integration

The checked-in workflow validates the root Flutter application. It has two
Linux jobs:

| Job | Checks |
|---|---|
| `analyze-test` | dependency resolution, formatting, static analysis, unit and widget tests |
| `build-linux` | Linux toolchain setup and a release-mode desktop build |

Both jobs use Flutter 3.47.1 stable. The Linux build installs clang, CMake,
Ninja, GTK 3, libmpv, and mpv before compiling.

## Local parity

From the repository root:

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build linux --release
```

Generated output lives under `build/` and is ignored. CI never depends on a
checked-in build directory or a legacy language toolchain.

Live Jimaku, debrid, and dictionary tests are opt-in and secret-gated. The
normal test suite must remain hermetic: it does not consume API quotas, resolve
torrents, or join a swarm.

## Releases

Desktop bundles must be built on their target operating system. Android release
artifacts require a private keystore before distribution, and macOS distribution
requires signing and notarization credentials. Those credentials must remain in
the release environment, never in this repository.
