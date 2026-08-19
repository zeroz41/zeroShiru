# zeroShiru

A personal anime library manager for watching and tracking your collection in
real time. Lightweight, powerful, and paws-itively fast. No waiting required!

Svelte frontend, shared Rust core (torrenting, debrid, media parsing, source
resolution), hosted by Tauri 2 on desktop and Android. Samsung Tizen and LG
webOS hosts reuse the same frontend with the core compiled to WebAssembly.

- Streams from debrid services (AllDebrid, Premiumize, Real-Debrid, TorBox) or
  directly over BitTorrent
- Tracks watch progress with AniList / MyAnimeList
- Embedded player with ASS subtitles, chapters, fonts, and external-player
  handoff
- Watch Together sessions

## Build & run

See [BUILDING.md](BUILDING.md). Short version:

```bash
bun install
bun run tauri:dev
```

## License

GPL-3.0-or-later
