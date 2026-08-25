# zeroShiru

A personal anime library manager for watching and tracking your collection in
real time. Lightweight, powerful, and paws-itively fast. No waiting required!

Pure Dart/Flutter application — Impeller renders the UI, libmpv renders video
into a Flutter external texture. No web runtime, no Rust, no Node. See
[docs/architecture/flutter-rewrite-architecture.md](docs/architecture/flutter-rewrite-architecture.md)
for the full design.

- Streams from debrid services (AllDebrid, Premiumize, Real-Debrid, TorBox) or
  directly over BitTorrent
- Tracks watch progress with AniList / MyAnimeList
- Embedded libmpv player with ASS subtitles, chapters, fonts, and
  external-player handoff
- Opt-in [Japanese learning subtitles](docs/features/language-learning.md) with
  interactive words, local JMdict definitions, furigana, romaji, and a second
  authored translation track; missing Japanese episode text can be fetched and
  cached through a user-connected Jimaku account
- Watch Together sessions

The previous Svelte/Tauri/Rust implementation lives on the `redo` and
`zeroz-dev` branches as the behavioral reference.

## Build & run

```bash
cd app
flutter pub get
flutter run -d linux
```

Requires Flutter 3.47+ and, on Linux, the desktop toolchain
(`clang`, `cmake`, `ninja`, `gtk3`) plus `libmpv`.

Tests:

```bash
cd app
flutter analyze
flutter test
```

## License

GPL-3.0-or-later
