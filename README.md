<p align="center">
  <img src="assets/images/zero-mark.png" width="320" alt="Zero">
</p>

# Zero

Zero is a focused anime library manager for watching, learning, and tracking a
collection in real time.

It is one pure Dart/Flutter application: Impeller renders the interface and
libmpv renders video into a Flutter external texture. There is no web runtime,
Rust workspace, or Node toolchain in the current application.

- Stream through AllDebrid, Premiumize, Real-Debrid, or TorBox
- Track progress with AniList and MyAnimeList
- Play through embedded libmpv with ASS subtitles, chapters, fonts, and
  external-player handoff
- Use opt-in [Japanese learning subtitles](docs/features/language-learning.md)
  with interactive words, local JMdict definitions, furigana, and romaji

## Develop

Zero is the only application package in this repository, so its `pubspec.yaml`
and platform projects live at the repository root.

```bash
flutter pub get
flutter run -d linux
```

Flutter 3.47.1 or newer is required. Linux development also needs `clang`,
`cmake`, `ninja`, GTK 3, libmpv, and mpv.

Run the same checks as CI:

```bash
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Build a release on the operating system being targeted:

```bash
flutter build linux --release
flutter build windows --release
flutter build macos --release
flutter build apk --release --split-per-abi
```

### Tizen TV

The Tizen runner will live at root-level `tizen/`, matching the other Flutter
platform projects. It is not named `tizenos/`. Tizen is a planned target rather
than a working build today: the official Flutter-Tizen toolchain is not part of
this repository, and the current media/plugin stack still needs Tizen adapters.

When that work begins, generate the runner with `flutter-tizen create .` instead
of committing an empty or hand-written placeholder, then build and validate it
on a Samsung TV with `flutter-tizen build tpk --device-profile tv`. See the
[Tizen target notes](docs/platforms/tizen.md) for the acceptance checklist.

Flutter writes generated artifacts to `build/`. That directory is ignored and
safe to recreate; it is not part of the source architecture.

## Structure

```text
lib/app/              composition root, routing, shell, theme, shared widgets
lib/features/         screens and feature-owned presentation
lib/application/      Riverpod state, controllers, and use cases
lib/domain/           platform-neutral models, policies, and ports
lib/infrastructure/   HTTP, database, tracking, debrid, media, platform adapters
test/                  unit and widget tests
assets/                fonts and canonical Zero brand assets
third_party/           narrowly patched native dependencies
android/ linux/ macos/ windows/  current generated platform runners
tizen/ webos/                    future runners, added when buildable
docs/ fixtures/
```

Dependencies point inward: presentation uses application/domain APIs;
infrastructure implements domain ports; only the composition root wires concrete
adapters. Pure filename, hash, and pack-selection policy belongs in `domain/`,
not in `infrastructure/`.

See the [architecture report](docs/architecture/flutter-rewrite-architecture.md)
for the full design and [CI notes](docs/CI.md) for validation details.

## License

GPL-3.0-or-later
