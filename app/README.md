# zeroShiru Flutter app

The complete application lives in this package. It is pure Dart/Flutter: the
UI is rendered by Flutter and video is rendered by libmpv through the vendored
`media_kit_video` adapter.

## Supported development targets

- Linux desktop (primary development and CI target)
- Windows 10/11 desktop
- macOS 12+ desktop
- Android and Android TV

Web and iOS projects are not present. Tizen and webOS are later targets tracked
in [`docs/porting/implementation-status.md`](../docs/porting/implementation-status.md).

## Prerequisites

Install Flutter **3.47.1 stable** and verify that its bundled Dart SDK is
**3.13.1 or newer**:

```bash
flutter --version
flutter doctor -v
```

Use the Dart SDK bundled with Flutter. A separately installed `dart` can be a
different version and cannot repair a mismatched Flutter tool snapshot.

Platform toolchains:

- Linux (Debian/Ubuntu): `clang`, `cmake`, `ninja-build`, `pkg-config`, GTK 3,
  libmpv, and mpv.

  ```bash
  sudo apt-get update
  sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev mpv
  ```

- Windows: Visual Studio 2022 with **Desktop development with C++** and the
  Windows 10/11 SDK. Confirm the toolchain with `flutter doctor -v`.
- macOS: Xcode, Xcode command-line tools, and CocoaPods. Open Xcode once to
  accept its license and install components.
- Android: Android Studio/SDK, an accepted SDK license set, and JDK 17. The
  checked-in Gradle project compiles and targets Java 17.

## Fetch dependencies and run

From the repository root:

```bash
cd app
flutter pub get
flutter devices
flutter run -d linux
```

Replace `linux` with a device ID printed by `flutter devices`, such as
`windows`, `macos`, or an Android emulator/device ID.

## Source extensions

Open **Settings → Extensions** and install a Shiru catalog such as
`gh:Spithskia/Shiru-Extensions`. The app reads the repository's declarative
`index.json` metadata and runs recognized source IDs through native Dart
adapters. It never downloads or executes extension JavaScript.

The bundled adapter registry supports Nyaa, Sukebei, SeaDex, AnimeTosho
Archive/New, nekoBT, and TsukiHime. Other legacy catalogs can be inspected and
installed, but an unknown source stays disabled and is labelled **Native adapter
required** until it is ported or rewritten using a future declarative source
schema.

## Language-learning subtitles

Learning mode is an opt-in native Flutter overlay for Japanese text subtitle
tracks. Open **Settings → Learning** to choose the display layers and install
the local Japanese–English JMdict cache, then choose **Learning** in the
player's subtitle panel. Standard mode remains the default and continues to
render authored ASS styling through libass.

Learning mode needs a timed text track (ASS, SRT, or WebVTT) in Japanese. It
can pair that with an English or other translated text track. Bitmap PGS and
VobSub tracks still play in Standard mode, but require a text sidecar to become
interactive. See the [language-learning design and privacy notes](../docs/features/language-learning.md).

## Validate a change

The same fast checks run in CI:

```bash
cd app
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Run one test while iterating with, for example:

```bash
flutter test test/features/schedule_page_test.dart
```

Tests are hermetic by default. Live tracking, debrid, and torrent tests must be
explicit, secret-gated suites when those lanes are added; ordinary unit/widget
tests must never consume service quotas or join a swarm.

The TorBox smoke test is opt-in and read-only: it validates the account and
checks cached availability for public-domain sample hashes. It does not add or
resolve a torrent:

```bash
ZEROSHIRU_LIVE_TORBOX_KEY='…' \
  flutter test test/debrid/live_torbox_test.dart
```

## Release builds

Build on the operating system being targeted:

```bash
# Linux
flutter build linux --release

# Windows (run on Windows)
flutter build windows --release

# macOS (run on macOS)
flutter build macos --release

# Android sideloading artifacts
flutter build apk --release --split-per-abi

# Android Play bundle
flutter build appbundle --release
```

Flutter writes artifacts beneath `app/build/`. The current Android release
configuration uses the debug signing key so local release-mode testing works;
configure a private release keystore before distributing an APK or AAB. macOS
distribution likewise requires project-specific signing and notarization.

Linux's `media_kit_video` dependency is a narrow local patch. Read
[`third_party/media_kit_video/ZEROSHIRU_PATCH.md`](third_party/media_kit_video/ZEROSHIRU_PATCH.md)
before upgrading `media_kit` or replacing the vendored package.

## Project map

```text
lib/app/              bootstrap, routing, shell, theme, shared widgets
lib/application/      Riverpod providers and use cases
lib/domain/           platform-neutral models and capability ports
lib/features/         screens and feature widgets
lib/infrastructure/   HTTP, database, tracking, debrid, media, platform adapters
test/                  unit and widget tests
third_party/           narrowly patched native dependencies
```

The architecture and full-product scope are defined in
[`docs/architecture/flutter-rewrite-architecture.md`](../docs/architecture/flutter-rewrite-architecture.md)
and the three maps under [`docs/porting/`](../docs/porting/). Keep the
implementation-status matrix current whenever a scoped capability lands.
