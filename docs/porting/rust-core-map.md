# PORTING MAP — Rust → pure Dart

Surveyed from the `redo` branch. Old code reference: `git show redo:<path>` or the reference worktree.

Total surface: ~16.7k LOC Rust across 11 crates + 3.8k LOC Tauri host. ~330 Rust unit tests.

---

## 1. DEBRID — `crates/debrid` (7.5k LOC, the largest and highest-risk port)

### 1.1 The four providers

| id | title | base URL(s) | auth | availability | notes |
|---|---|---|---|---|---|
| `torbox` | TorBox | `https://api.torbox.app/v1/api` | Bearer; **except** `/torrents/requestdl` which uses `?token=<key>` | `Batch` (`/torrents/checkcached`) | responses wrapped `{success,data,error,detail}`, failures inside HTTP 200 |
| `realdebrid` | Real-Debrid | `https://api.real-debrid.com/rest/1.0` | Bearer (`auth_param` "apikey") | `Probe` + `check_adds_magnets` | raw JSON, `error_code` int drives mapping |
| `alldebrid` | AllDebrid | `https://api.alldebrid.com/v4` and `…/v4.1` (status + file tree moved to 4.1) | Bearer (`apikey`) | `Batch` **but** `check_adds_magnets = true` | `{status,data,error}` envelope, failures in 200 |
| `premiumize` | Premiumize | `https://www.premiumize.me/api` | Bearer (`apikey`) | `Batch` (`/cache/check`), costs nothing | failures in 200, payload at top level (no envelope) |

`PROVIDER_IDS = ["alldebrid","premiumize","realdebrid","torbox"]` — menu order; hosts enumerate, never name.

**Endpoints actually used**

- **TorBox**: `GET /user/me?settings=false`; `GET /torrents/mylist?limit=1000[&id=][&bypass_cache=true]`; `POST /torrents/createtorrent` (multipart: `magnet`, `seed=3` never-seed, `allow_zip=false`); `GET /torrents/checkcached?hash=..&hash=..&format=list`; `GET /torrents/requestdl?torrent_id=&file_id=&redirect=false` (query-token auth); `POST /torrents/controltorrent` (JSON `{torrent_id, operation:"delete"}`).
- **Real-Debrid**: `GET /user` (must be `type == "premium"`); `GET /torrents?limit=…`; `GET /torrents/info/{id}`; `POST /torrents/addMagnet` (`magnet`); `POST /torrents/selectFiles/{id}` (`files=all` or CSV ids); `POST /unrestrict/link` (`link`); `DELETE /torrents/delete/{id}`.
- **AllDebrid**: `POST /v4/magnet/upload` (`magnets[]` repeated); `POST /v4.1/magnet/status` (`id` optional); `POST /v4/magnet/files`; `GET /v4/link/unlock?link=<encodeURIComponent>`; `POST /v4/magnet/delete`; `GET /v4/user`.
- **Premiumize**: `GET /account/info`; `POST /cache/check` (`items[]` repeated, **positional answer array**); `POST /transfer/directdl` (`src=<magnet>`) — read-only cache read, adds nothing.

### 1.2 Per-provider config constants (port verbatim — measured, not guessed)

```
TorBox:     nominal_latency 300, max_files 12,  max_batch 75, max_probes 10,
            max_concurrent 3, min_time 200ms, reservoir (300, 60s)
RealDebrid: nominal_latency 300, max_files 60,  max_batch 100, max_probes 10,
            max_concurrent 4, min_time 150ms, reservoir (200, 60s)
AllDebrid:  nominal_latency 300, max_files 60,  max_batch 10,  max_probes 10,
            max_concurrent 3, min_time 250ms, reservoir none
Premiumize: nominal_latency 300, max_files 60,  max_batch 100, max_probes 10,
            max_concurrent 3, min_time 250ms, reservoir none
Timeouts (all): request 30s, select 12s, ready 5s, poll 1s, probe 10s, resolve 60s
```

`max_files: 12` for TorBox exists because a 60-link burst against `/torrents/requestdl` earned `429 retry-after: 300`.

`max_ask()` = `max_probes` when `Probe` **or** `check_adds_magnets`, else unlimited. AllDebrid needs both branches.

### 1.3 Cached-availability check flow (`manager.rs`)

1. Normalize magnets/hashes → lowercase, dedup, order preserved, truncated at `max_ask()`.
2. Remembered answers returned free (`recall`, TTL below). Only unknowns are asked about.
3. If `check_adds_magnets`: take a single global "sweeping" claim (a second caller returns memory-only answers); **released by a `finally`/`Completer` guard, not by post-await code** — a cancelled call left the flag true forever and every later check silently returned memory only.
4. Before adding anything: if orphaned removals exist, `retry_cleanup()` first.
5. `Batch`: chunk by `max_batch`, chunks run **concurrently** (`Future.wait`) — serial chunks made long lists badge in visible waves. A hash absent from the answer = `Unknown`, never "not cached". A failed chunk leaves its own hashes unknown; other chunks keep their answers, error still reported.
6. `Probe`: worker pool of 3 over a shared queue. Stops early on auth, on `throttled`, or after **3 consecutive** failures. `Ok(None)` (hash already in flight) is neither answer nor failure. Answers published the instant they land, not at the end.
7. `watch_availability` = the whole badge lifecycle: remembered answers → check round → retries on backoff `10s`, doubling to `4min`. Any progress (or a busy sweep) resets to 10s. Auth failure ends the watch. Events: `Answer{hash,state,name}`, `Checking(bool)`, `Outage(error)`, plus a `settled` marker from the host.

**Availability TTLs** (`crates/domain/availability.rs`): `Cached` 6h, `Available` 20m, `Unavailable` 30m, `Unknown` 0.

Per-provider availability derivation:
- TorBox: `download_present` truthy **or** (`download_finished` && `progress == 1.0`) → Cached; `download_state` containing stalled/error/failed/missing → Unavailable; else Available. Hashes left out of `checkcached` → Available (TorBox *would* fetch it).
- RealDebrid: torrent status table; `waiting_files_selection`/magnet conversion mean nothing (a moment, not an outcome).
- AllDebrid: `ready` truthy → Cached; upload `error.code` in DEAD_CODES → Unavailable; codes about a busy account → **not** an answer.
- Premiumize: positional `response[i]` truthy → Cached else Available. A hash that can't be parsed still holds its slot (empty string) or everything after shifts.

### 1.4 Link unlocking / signed-URL flow

- **TorBox**: `resolve` → check cached (skipped if memory says Cached) → `createtorrent` (or reuse account entry; `DUPLICATE_ITEM` is an answer, not a failure) → poll `mylist?bypass_cache=true` until settled within `budget(ready)` → filter with `file_filter` → `pick_file` (or largest, first-on-tie) → `window_files` → **`request_links`**: the target file's request is polled first so it takes the first limiter ticket; neighbours run concurrently; once the target answers, neighbours get only **2s grace** (`OPTIONAL_LINK_GRACE_MS`) before results are returned without them. Output re-sorted back into torrent order.
- **RealDebrid**: reuse account torrent, or `addMagnet` + `selectFiles`; await `downloaded`; `unrestrict/link` per file **concurrently**; links/selected-files alignment decides whether to filter by path or by filename; archives dropped; if the target file is missing from the results, RD packed an archive → re-add selecting only that one file id, retry, then delete the first torrent.
- **AllDebrid**: upload magnet → status → flatten file tree (`n` name, `s` size, `l` link, `e` folder children) into rooted paths → `link/unlock` per file concurrently.
- **Premiumize**: single `transfer/directdl` returns every link. Empty content = not cached. Release name synthesised from the pack folder or the file.

Universal: `secure_files` drops any non-`https://` URL and errors if nothing secure remains — enforced in the manager, not trusted to providers.

### 1.5 Rate limiting / retry / error semantics

`limiter.rs` — three gates checked in order: (1) a service-requested pause, (2) reservoir tokens per window, (3) `max_concurrent` + `min_time_ms` spacing. **FIFO ticketing is load-bearing**: providers deliberately put the user's episode at the head of a pack's link burst; a limiter that reorders plays the wrong episode under load. Permits and tickets must be released on failure *and* on cancellation (`try/finally` around every acquire; a dropped waiter must not wedge the queue).

Retry policy in `client.request`:
- `429` → retry up to **2** times; honour `retry-after` (seconds) or default **5s**; **refuse to wait past 30s** (TorBox has sent `retry-after: 300`, freezing playback for 5 min). The pause applies to the *whole account*, not just the offending request.
- `Timeout` → exactly **one** more attempt after a 3s delay — **unless the service was already known-quiet at entry**.
- Everything else (auth, 5xx, unreachable) → no retry.

Error taxonomy (`DebridError`): `Auth`, `Network`, `Timeout`, `NotCached`, `Unavailable`, `Rejected`, `Service{status,code}`. `proven_availability()`: only `NotCached → Available` and `Unavailable → Unavailable`; timeouts/rate limits/500s prove **nothing**. `Rejected` = the caller's picker refused the release (episode provably absent) — never retried, never an availability answer. `throttled()` = status 429, overridden by RealDebrid (error codes 34, 21) and Premiumize (its own codes rather than 429).

### 1.6 "Service goes quiet" degradation (TorBox flapping) — **port this exactly**

Constants in `client.rs`: `QUIET_COOLDOWN_MS = 30_000`, `QUIET_PROBE_MS = 3_000`, `QUIET_RESOLVE_BUDGET_MS = 15_000` (manager), `RESOLVE_HEALTH_POLL_MS = 500`.

- One full-budget timeout sets `quiet_timeouts++` and `quiet_at = now`. `quiet()` is true while `quiet_timeouts > 0 && now - quiet_at < 30s`.
- While quiet, every request's timeout is clamped to `budget(3_000)` — it only asks "did it come back?".
- **Any** response, even an error status, clears the state instantly.
- The timeout retry is skipped while quiet (that chain of full-budget waits was the original 30–60s spinner).
- The end-to-end resolve deadline *watches* the quiet flag while running — quiet can turn on mid-resolve — and shortens the 60s budget to 15s from the moment it does.

Origin: TorBox wedges per-endpoint, accepting connections and never answering, for minutes, while `curl` proves the server up (2026-08-19 and 2026-08-22).

### 1.7 Slow-link handling

`observe_latency`: EWMA `(known*7 + sample*3)/10`, only from round trips that came back (a timeout can't inflate it). `budget(base)` = `base * clamp(latency / nominal_latency, 1.0, 3.0)`. Every poll budget stretches; the hard `request` ceiling does not.

### 1.8 Other state a Dart port must reproduce

- **Availability memory** keyed by hash with timestamps + TTL; `Unknown` *removes* rather than stores.
- **Release-name memory** — services name releases for free on answers.
- **Account listing cache**, TTL **60s**, guarded by an *async* mutex so a second caller waits for the in-flight read. `amend_listing(entry, same)` patches one entry rather than dropping the whole listing.
- **Orphan removals** (`OrphanOnDrop`): a cancelled resolve/probe leaves a torrent on the account. Dart needs explicit `try/finally` + cancellation discipline. Retried max 3 times, keyed by *whole request* (URL+body), never persisted. 404 counts as gone.
- `PROBE_HANDOVER_MS = 5000` / poll 100ms: a resolve waits out an in-flight probe of the same hash, else the probe deletes the torrent out from under playback.
- `window_files(files, target, max)` — keeps the wanted episode reachable, centres the window on it, clamps at both ends without shrinking, preserves torrent order, degrades to the head when there's no target.
- `map_files` — concurrent, skips files the service won't link (packs contain dead files) but **aborts on auth**.

---

## 2. TORRENT — `crates/torrent` (1.9k LOC)

**Engine**: was `librqbit 9`. Pure-Dart replacement is the phase-6 project; the `TorrentEngine` port is the seam.

**Engine surface**: `add`, `metadata`, `select_files(indexes)` (replaces the whole selection each call), `select_file`, `playback_source`, `pause`, `resume`, `remove`, `status`. Session options from settings: DHT (+port), fastresume, listen addr with UPnP, download/upload bps limits, tracker list, peer limit. `set_rate_limits` applies live.

**Loopback HTTP Range gateway** (`gateway.rs`):
- Bind `127.0.0.1:0` (ephemeral). One route: `GET /{token}/{hash}/{fileIndex}`.
- **Capability token**: 24 random bytes hex = 48 chars, per session, in the path. Wrong token answers `404`, not `403` — no oracle.
- Range: only `bytes=start-` and `bytes=start-end` (first spec of a multi-range used). Invalid/out-of-range → treated as no range (full body, `200`). Valid → `206` with `Content-Range: bytes s-e/total`. Always `Accept-Ranges: bytes`, `Content-Length: end-start+1`, `Content-Type: application/octet-stream`.
- Piece prioritization is in file selection + the engine's stream/seek, not the gateway.

**External player** (`session.rs`):
- Discovery: configured `playerPath` wins; otherwise on Linux try `mpv`, `vlc`, `gst-play-1.0`, `ffplay` via `$PATH` + executable bit.
- **mpv special-case**: args `--force-media-title=<title>` + `--playlist=-`, URL written to **stdin** then the pipe closed — argv leaks a signed URL to process viewers and mpv's derived title leaks it in the window title. Other players get the historical one-argument contract.
- Title: `zeroShiru — <name>`, control chars stripped, 160 chars max; `zeroShiru` when empty.
- Emits `ExternalReady` on spawn, `ExternalWatched(seconds)` on exit.

**Session lifecycle / roles**: `Current | Staging | Seeding | Completed`, persisted to `<downloadDir>/shiru-session.json` (name, size, magnet, date, role, incomplete). Ops: `stream`, `stage`, `unload`, `untrack` (deletes data), `complete` (stop seeding, keep files), `rescan`, `set_playback`, `launch_external`, `update_settings`, `scrape`. Demotion: finished → Seeding (seeding limit enforced by evicting the **highest-ratio** torrent to Completed); unfinished + persist → Staging; else delete with data.

**Wire events**: `stats`, `currentStats`, `progress`, `files`, `loaded`, `notify`, `externalReady`, `externalWatched`. Loops: 200ms current-stats tick, 5s progress/snapshot tick. Speeds are `mbps * 125_000`.

**Tracker scrape**: announce URL → scrape URL per BEP 48 (`/announce` → `/scrape`, HTTP only), plus a minimal bencode walk of `d5:filesd<20-byte hash>d…ee`. ~120 LOC, port as-is.

**PlayerFile identity**: `fileHash = sha1("{infoHash}:{name}:{size}")` — must be byte-identical between the torrent and debrid lanes or watch progress/resume silently restarts. MIME map for ~20 extensions in `mime_for`.

---

## 3. SOURCES + MEDIA + CORE (picking)

### `crates/sources` (52 LOC)
`normalize(id)` → `Direct{url}` for http(s), `Torrent{info_hash, magnet?}` for magnets/hashes, `None` otherwise.

### `crates/media/filename.rs` (564 LOC) — **highest-value algorithm in the repo**
Anime filename recognizer. Answers exactly two questions: which episode numbers does this name claim, and is it an extra. Everything else answers "no idea" deliberately — a confident wrong number plays the wrong episode.

- Tokenizer: bracket groups `[] () {}` marked `enclosed`; delimiters space/underscore/plus/dot — **except a dot between digits with a 1–2 digit terminated fraction** (`12.5` is an episode, `E05.1080p` is two words). A lone `-` becomes a `separator` token.
- `ReleaseKind`: Creditless (NCOP/NCED/CREDITLESS/NC), Theme (OP/ED/OPENING/ENDING), Ova (OVA/OAD), Ona, Special (SP/SPECIAL/SPECIALS/OMAKE), Promo (PV/CM/PREVIEW/TRAILER/MENU/BONUS/EXTRA). Creditless wins over any later kind.
- Episode candidates in strict priority, first hit wins: `season_episode` (`S01E05`, `S01`+`E05`, `1x05` — season capped at 2 digits so `1920x1080` isn't episode 1080) → `prefixed_episode` (EPISODE/EPS/EP/E, longest prefix) → `kind_numbered` (`NCOP1`, `SP01`, `OVA 02`) → `after_separator` (`Title - 05`) → `bare_number` (**last** standalone number, skipping years 1900–2100 and decimals after an audio tag like `AAC 5.1`) → a bracket containing only a number.
- `episode_range`: `"01-12"` → `[1,12]`; a descending pair (`12-05`) is one episode, not a range. `v2` suffix stripped and reported as `version`.
- Data-driven constants: kind keywords, audio tags, video/subtitle/font extension lists. Algorithmic parts for a faithful port: the tokenizer's decimal rule, the priority ladder, the year/audio-tag guards.

### `crates/media/matroska.rs` (483 LOC)
Streaming EBML parser over a byte prefix. `NeedMoreData` is a normal signal, not corruption; `Segment` has unknown size in streamed muxes so descend, don't skip; stop at first `Cluster`. Extracts `Info` (title, duration via `TimestampScale`, default 1e6 ns) and `Tracks` (number, kind 1/2/17→video/audio/subtitle, codec id, name, language with `LanguageBCP47` overriding legacy `Language`, default `"eng"`, default/forced flags, `CodecPrivate` kept only for subtitle tracks). Largely unnecessary in Flutter (libmpv reads its own container) — keep only if something needs track info before open.

### `crates/core/pick.rs` (507 LOC) — pack episode selection
`pick_episode_file(files, episode, parse)`:
1. Filter to video files. ≤1 video → that one (or file 0).
2. Rank matches: **0** = episode & exact, **1** = episode & range, **2** = extra & exact, **3** = extra & range. First file in torrent order wins within a rank. This is why `NCOP1` never shadows real episode 1.
3. If *every* video parsed to a number and none covers the request → **`EpisodeNotInPack{episode, first, last}`**, refusing outright. Origin: asking a 459–516 pack for episode 23 used to play episode 475. The reported span reads off *real* episodes only.
4. Otherwise fall back to the largest **non-extra** video, first on ties.

`pick_pack_file` softens step 3: when the whole release fits within `max_files` (nothing windowed away), a mismatch returns `Ok(None)` and hands the choice to the player (which knows season offsets). Only a release too big to hand over whole is refused.

---

## 4. NETWORKING — `crates/networking` (639 LOC)

**SSRF guard** (`guard.rs`):
- Scheme must be http/https. Host extracted without userinfo (last `@` wins), port, or path; `[::1]:8080` → `::1`.
- IP literals checked directly. Names: `localhost` and suffixes `.local .localhost .internal .home.arpa .onion` blocked; a name with **no dot** is blocked as `NotPublicName`.
- `is_public_addr` blocks v4 loopback/private/link-local/broadcast/documentation/unspecified/multicast, `0.0.0.0/8`, CGNAT `100.64/10`, `192.0.0.0/24`, benchmarking `198.18/15`, and `>= 240`. v6: unmap v4-mapped first, then block loopback/unspecified/multicast, ULA `fc00::/7`, link-local `fe80::/10`, discard `0100::/8`, documentation `2001:db8::/32`.
- Blocked reasons typed: `Scheme | NoHost | Private | NotPublicName`.

**Redirect policy** (`hosts/tauri/src/net.rs`): redirects followed, but **each hop re-checked with the same guard**; max 8 hops; final landing URL checked again after the response. Body cap 8 MB (content-length *and* after reading). Timeout default 20s, cap 60s. Methods allowlist GET/POST/PUT/DELETE/PATCH/HEAD. Headers the transport owns are stripped: `host, content-length, connection, transfer-encoding, upgrade`; `User-Agent/Referer/Cookie/Authorization/X-Api-Key` pass through.

**Redaction is structural**: (a) debrid links never enter argv or window titles (mpv stdin), (b) API keys travel as Bearer headers, never in URLs, except TorBox's `requestdl` (explicit tests exist for AllDebrid/Premiumize), (c) the gateway token is a path capability answering 404 on mismatch, (d) renderer log lines clamped to 2000 bytes and 20 000 lines per run.

**Reachability** (`reachability.rs`): probes `https://cp.cloudflare.com/generate_204` then `https://connectivitycheck.gstatic.com/generate_204`, stopping at the first proper answer. States: `online | portal | offline | unknown`. **A timeout is `unknown`, not `offline`.** Only connect-level failure at *every* endpoint is `offline`. Minimum timeout floor 2s.

**HTTP abstraction**: `Method`, `HttpRequest{method,url,headers,body,timeoutMs}`, `Body.bytes{contentType,bytes} | Body.multipart(fields)`, `HttpResponse{status,headers,body}` with case-insensitive `header()`, `TransportError.network | .timeout(ms)`. Keep the seam — the whole debrid layer is written against it and all provider tests inject a mock.

---

## 5. DOMAIN — `crates/domain` (396 LOC, mirror it all)

- `Availability` + order + `normalize` + `streamsInstantly` + `ttl()` + `describe(title)`.
- `parse_hash(magnetOrHash)` → first case-insensitive `urn:btih:<40 hex>`, else a bare 40-hex string, lowercased. `to_magnet` passes magnets through, wraps hashes.
- `DebridFile{name, path (rooted), size, url (https), type?}`, `DebridResolved{hash, name, files (torrent order), target?}`.
- `PlayerFile{infoHash, fileHash, torrent_name (snake_case on the wire — legacy), name, type?, size, path, url, debrid}` + `watchKey(infoHash,name,size) = sha1Hex("$infoHash:$name:$size")`.
- `StreamCandidate.direct | .torrent{infoHash,magnet?,fileIndex?} | .debrid{provider,id}`; `PlaybackSource.direct | .debrid{provider,url} | .torrent{infoHash,url}`.
- `platform-contracts`: `PlatformCapabilities{localP2p, debrid, directHttp, nativeMediaStack}` with `DESKTOP/ANDROID/TV_WEB` presets, `InputCapabilities`, `LayoutProfile{desktop,mobile,tv}`.
- Standing contract: **API keys are never ordinary settings entries** (OS keyring only).

---

## 6. What the Flutter host must provide (was hosts/tauri, 3.8k LOC)

| Area | Behavior to keep |
|---|---|
| **Windowing** | min 320×390, initial 1280×800, background `#17191C`, show only after first paint |
| **Tray** | icon with Show/Quit; left-click restores |
| **Deep links** | `shiru://` and `magnet:` schemes; single-instance forwarding; routing table stays in the app |
| **Updater** | signed only; stable `…/releases/latest/download/latest.json`, nightly `…/releases/download/nightly/latest.json`; events available→progress→downloaded; statuses `available/up-to-date/unconfigured/failed`; `unconfigured` when no signing key; checks every 30 min |
| **Log file** | `<configDir>/main.log`, rotated once at startup past 8 MB to `main.log.1`; live-swappable level; export (`zeroshiru-<epoch>.log`) and reset (truncate in place, same inode). Capture `FlutterError.onError` + zone errors into the same file, clamp 2000 bytes/line, 20 000 lines/run |
| **Diagnostics snapshot** | pull-based `{version, uptimeMs, log{path,sizeBytes,rendererLines,cap}, debrid: [ServiceHealth{service, quiet, unansweredTimeouts, latencyMs, rememberedAnswers, orphanedRemovals, sweeping, requestsInFlight, requestsWaiting, pausedForMs}], mediaCache}` — every debugging session started by discovering the explaining state existed only in memory |
| **Art cache** | content-addressed `<cacheDir>/media/<sha256(url)>`, mtime LRU, cap 512 MB trim to 90%, max image 24 MB, 25s fetch timeout, in-flight dedup, failure memo 10 min in memory only |
| **Host debrid state** | provider cache keyed by `(service, apiKey)`, **4 slots** LRU (1 slot: the settings "test" button evicted the live account mid-flight). Resolved-link cache: TTL **15 min**, 64 slots, keyed by (service, key, hash, target-window); `retarget` re-picks from a cached window and is **strict** (a cached slice is not the whole release). `forget_resolved` drops **every** window for a hash |
| **Lenient hashes** | results lists contain `null` where a source gave no hash; drop non-strings, answer the rest — a strict decode leaves every badge empty |
| Lower priority | Discord RPC; taskbar badge; native pickers; notifications. The WebKit graphics ladder is obsolete |

---

## 7. Tests & fixtures worth reusing (~330 Rust tests + a JS suite)

| Where (on redo) | Count | Why |
|---|---|---|
| `crates/core/src/pick.rs` (two test mods) | 30 | Pack selection incl. real regressions: 459–516 One Piece pack refusing ep 23, NCOP1 not shadowing ep 1, `12.5` vs `12`, exact-beats-batch, torrent-order tie-breaks, split-cour 13–24 handed to the player |
| `frontend/test/fixtures/fr-one-piece-459-516.json` | — | golden pack fixture |
| `crates/media/src/filename.rs` | 14 | filename vectors |
| `crates/debrid/src/providers/torbox.rs` | 32 | golden request/response bodies, DUPLICATE_ITEM, 2s neighbour grace |
| `crates/debrid/src/providers/realdebrid.rs` | 27 | archive-recovery path, aligned vs unaligned links, probe leaves account untouched |
| `crates/debrid/src/providers/alldebrid.rs` | 19 | envelope helpers, file-tree fixture, removes only the magnets it created |
| `crates/debrid/src/providers/premiumize.rs` | 15 | positional cache/check ordering |
| `crates/debrid/src/client.rs` | 21 | retry/quiet/latency/listing-cache semantics |
| `crates/debrid/src/manager.rs` | 18 | sweep stopping, watch backoff, claim release on cancellation |
| `crates/debrid/src/limiter.rs` | 8 | FIFO ordering, dropped-waiter, pause-wins-longer |
| `crates/debrid/src/window.rs` | 8 | windowing around the target |
| `crates/media/tests/matroska.rs` + `crates/media/tests/fixtures/*.mkv` | 3 + 2 files | real-container vectors |
| `crates/networking/src/guard.rs` / `reachability.rs` | 11 / 13 | SSRF table, timeout-is-not-offline |
| `hosts/tauri/src/net.rs` | 9 | redirect-into-local refusal, header allowlist |
| `crates/torrent/src/session.rs` | 10 | signed-URLs-out-of-argv, PlayerFile identity, scrape/bencode |
| `crates/torrent/src/gateway.rs` | 3 | Range parsing table |

**Test infrastructure to reimplement first**: `crates/debrid/src/testing.rs` — `MockTransport` (URL-substring routes, `Answer/Network/Timeout/Pending` outcomes, records requests, per-request latency vs a shared clock) and `ManualClock` (`sleep` advances the clock *and yields*) — nearly every debrid test depends on these.

**Live suites** (opt-in, quota-consuming): `crates/debrid/tests/live.rs` (asserts account torrent count unchanged after availability checks — keep that invariant), `frontend/test/live/**`, `frontend/test/unit/debrid/**`, `frontend/test/unit/playback/**` (~25 files) — the JS behavioural reference.
