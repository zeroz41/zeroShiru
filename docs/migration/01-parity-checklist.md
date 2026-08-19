# Phase 0 — Feature Parity Checklist

Every box must hold on the Tauri build before the corresponding legacy host is deleted.

## Desktop (gate for deleting Electron — Phase 10)
- [ ] Torrent: magnet load, metadata, DHT, trackers (HTTP/WSS/uTP), file select, stream,
      seek, seed cap (SUPPORTS.maxSeeding), session restore, untrack/cleanup
- [ ] Debrid: AllDebrid, Premiumize, RealDebrid, TorBox — cache/availability, add,
      pick, route, resume, slow-link handling, timeouts (mirror test/unit/debrid/*)
- [ ] Playback: embedded player, subtitles (JASSUB/ASS), embedded Matroska subtitle/track
      parsing, fonts (per-language once), chapters, coverage/progress, external player
- [ ] Providers: AniList + MyAnimeList auth (protocol handling), token flow, RSS
- [ ] Desktop integration: tray/window lifecycle, exit intent, unread count,
      Discord RPC (set/clear presence), DoH toggle, ANGLE selection, devtools,
      protocol handler (`shiru:`?), file/folder pickers, notifications (powertoast path),
      shutdown handler behavior on Windows
- [ ] Updater: stable + nightly channels, progress events, quit-and-install
- [ ] Logging: export/reset log
- [ ] Keybinds, themes, settings persistence, migration of existing user data/store

## Android (gate for deleting Capacitor — Phase 13)
- [ ] Foreground service torrenting, notifications, toast, splash, status bar style,
      back button, PiP, orientation, intents/external player, APK self-update,
      file access (SAF), keyboard behavior

## Open decisions
- [ ] `extensions/` system: declarative manifests interpreted by Rust core vs JS-side
      discovery + Rust normalization only  ← blocker for crates/sources design
- [ ] TV secure credential storage (pairing token vs stored key)
- [ ] Loopback media gateway vs custom protocol handler for torrent → player on desktop
