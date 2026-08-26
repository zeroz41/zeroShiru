# Zero → Flutter: Application/Service Layer Porting Map

Surveyed from the `redo` branch (commit d342051b era). Old code reference: `git show redo:<path>`.

Repo layout there: `frontend/common/` (Svelte 4 + JS app, ~36k lines), `hosts/tauri/` (Rust host + `bridge.js` injector), `crates/` (11 Rust crates). The service layer to port is almost entirely `frontend/common/modules/**`.

---

## 1. bridge.js contract (the host seam)

Contract file: `frontend/common/modules/bridge.js` (173 lines, the **only** file in `common/` allowed to touch a host API).
Host implementation: `hosts/tauri/src/bridge.js` (injects `window.torrent/common/android/desktop/zero`), backed by `hosts/tauri/src/commands.rs`, `torrent.rs`, `debrid.rs`, `desktop.rs`, `graphics.rs`, `net.rs`, `updater.rs`, `diagnostics.rs`.

Mechanism: page-side namespaces are `{...defaults, ...window.X}` merges over noops, so a host may implement its surface incrementally. Commands go down as Tauri `invoke`; state comes back on **three** event channels: `zero://torrent`, `zero://debrid`, `zero://update`, plus `zero://protocol` and `zero://exit-intent`. In Dart this becomes 5 capability ports (Torrent, Common/Host, Debrid, Desktop, Diagnostics) + 3 broadcast streams.

### TORRENT (`window.torrent` → `torrent_*` commands)
| Member | Payload / shape | Purpose |
|---|---|---|
| `start(settings)` | session settings object (see `torrentSettings()` in `modules/torrent.js`) | boot session, resolves when ready |
| `stream(id)` | `{id: string\|base64, base64: bool}` — magnet / 8-40 hex hash / `.torrent` URL / bytes | load for playback |
| `stage(id)` | same | background pre-download |
| `unload()` / `untrack(hash)` / `complete(hash)` / `rescan()` | hash string | stop playback / forget+delete / stop seeding keep files / refresh snapshot |
| `scrape(hashes)` | `string[]` → seeder/leecher counts | peer counts for results list |
| `setPlayback(current, external)` | file object + bool | tell engine which file the player opened |
| `launchExternal(current)` | file object | open in configured external player (mpv/VLC, signed URL via stdin) |
| `updateSettings(settings)` | same shape as `start` | live settings apply |

Events (all on `zero://torrent` as `{type, data}`, fanned out by type): `stats` (full snapshot `{current, staging[], seeding[], completed[]}`), `currentStats` (`{numPeers, uploadSpeed, downloadSpeed}`), `progress`, `files` (`PlayerFile[]`), `loaded` (`{infoHash, name, magnet}`), `notify` (`{type:'info'|'warn'|'error', message}`), `externalReady`, `externalWatched` (last two are single-slot listeners, re-registered per playback).

`PlayerFile` (from `crates/torrent/src/session.rs:115`) — **the universal player file shape, also produced by debrid**: `{ infoHash, fileHash, torrent_name, name, type (mime), size, path, url }`.

### COMMON (`window.common`)
`getAppVersion()`, `getPlatformInfo()` → `{platform, arch, development, capabilities{native_media_stack,…}}`, `getDeviceInfo()`, `mediaSrc(url)` (rewrites http(s) into the host media-cache scheme; non-network passes through), `notify({title, body})`, `windowReady()`, `isWindowVisible()`, `openURI(uri)`, `pickFile(filters)`, `pickFolder()`, `linkAccount()`, `exportLog()`, `resetLog()`, `log(entries[{level,scope,message}])` (nullable), `probeNetwork(timeoutMs)` → `'online'|'portal'|'offline'|'unknown'|null`, `request({url,method,headers,body,timeoutMs})` → `{url,status,ok,headers,body,binary}` (nullable; the CORS bypass), `onProtocol(cb)`, update channel: `setUpdateChannel`, `checkForUpdates`, `quitAndInstall`, `onUpdateAvailable/Downloaded/Progress/Aborted`.

### ANDROID (`window.android`)
`minimize`, `showSplash`, `toast`, `onBackButton`, `hideStatusBar`, `setSystemStyle('LIGHT'|'DARK')`, `requestFileAccess()→{granted}`, `launchExternal`.

### DESKTOP (`window.desktop`)
`exit`, `getGraphics()→{mode,modes[],overridden}`, `setGraphics(mode)`, `isMinimized`, `isFullScreen`, `onMinimize`, `onFullScreen`, `hideWindow`, `showAndFocus`, `onExitIntent`, `openDevTools`, `setUnreadCount(n)`, `setDiscordRPC(mode)`, `setPresence(data)`, `clearPresence()`, `getYouTube()`. (Plus `window.zeroWindow.minimize/toggleMaximize`.)

### DEBRID (`window.zero.debrid`)
| Member | Shape |
|---|---|
| `services` | inlined plain data `[{id, title, check_adds_magnets, …}]`; providers are `alldebrid, premiumize, realdebrid, torbox` (`crates/debrid/src/manager.rs:18`) |
| `validate(service, apiKey)` | → `{username, expires}` |
| `listAvailability(service, apiKey)` | → `{answers: {hash: state}, names: {hash: name}}` |
| `watchAvailability(service, apiKey, hashes[], requestId)` | starts/replaces a watch; answers arrive as events |
| `cancelAvailability()` | stops the watch |
| `remember(service, apiKey, hash, state)` | record a proven answer |
| `resolve(service, apiKey, magnet, episode\|null)` | → `{hash, name, files: PlayerFile[], target}` |
| `forgetResolved(service, apiKey, hash)` | invalidate a dead direct link |
| `onEvent(cb)` | `zero://debrid` `{type, data}` |

Debrid events: `availability` `{hash, state, name, requestId}`, `checking` `{active, requestId}`, `outage` `{kind, message, requestId}`, `settled` `{requestId}`. Error `kind` vocabulary (contract with `outageNotice`): `auth | network | timeout | not-cached | unavailable | rejected | service`.

### DIAGNOSTICS (`window.zero.diagnostics`)
`snapshot()` → host health or null; `setLogFilter(filter)` (tracing directives).

**Dead/unused**: `window.zero.routePlayback` / `route_playback` is exposed by the host but not called anywhere in `frontend/` — don't port.

---

## 2. `frontend/common/modules/*` module inventory

### Core infrastructure

- **`cache.js` (1746 lines) — the query/persistence layer.** IndexedDB, two databases: per-user and shared. Store definitions in `caches` (line 146):
  - User DB: `GENERAL` (settings, sync, mutation queues, torrent session mirrors, miniplayer pos), `USER_LISTS`, `HISTORY`, `NOTIFICATIONS`, `QUERY_NOTIFICATIONS`, `QUERY_FOLLOWING` (30d/2000), `QUERY_RECOMMENDATIONS` (30d/500).
  - Shared DB: `MEDIA_CACHE` (120d/10k), `EXTENSIONS`, and the **SWR stores**: `QUERY_MAPPINGS` (120d/5k), `QUERY_COMPOUND` (7d/500), `QUERY_EPISODES` (60d/1k), `QUERY_SEARCH_IDS` (30d/1k), `QUERY_SEARCH` (30d/1k), `QUERY_RSS` (30d/1k).
  - **Stale-while-revalidate rule**: only stores with `swr: true` may serve stale. User-owned stores never opt in. Two entry points: `cacheEntry(cache, key, vars, dataPromise, expiry)` (write-side: if `swr` and a promise and no `skipCache`, return stale immediately and land the fresh copy behind it) and `swrRead(cache, key, revalidateFn)` (read-side, one in-flight revalidation per entry via `#revalidating`). When the fresh copy differs from what was served, the `swrRevalidated` counter store increments and home rails repaint (`sections.js` subscribes).
  - Other API: `read/write`, `getEntry/setEntry/deleteEntry`, `cachedEntry(cache,key,ignoreExpiry)`, `requestMedia(id, isMal)`, `getMedia`, `updateMedia`, `patchMedia`, `abandon(cacheId)` (profile switch), `resetSettings/History/Extensions/Caches/Notifications`, `createBatchWriter` (debounced 1.5s batch flush), `flushAllWriters`, `canonicalKey`, `mapStatus` (MAL↔AniList status map), `fromCache`, `auditPersistence`. Also DB migrations v1→v2 and legacy key cleanups.
  - Stores exported: `mediaCache`, `swrRevalidated`, `migrationStatus`.
- **`settings.js` (284)** — the settings store (`writable` over `defaults` + scoped defaults + persisted entry in `GENERAL:settings`), `profiles` (localStorage), `sync` (which profile ids to mirror writes to), `alToken`/`malToken` (localStorage `ALviewer`/`MALviewer`), OAuth paste handler, `validateToken`, `refreshMalToken`, `swapProfiles`, `isAuthorized`.
- **`util.js` (927)** — `defaults` (all settings), `generalDefaults`, `historyDefaults`, `debounce`, `uniqueStore`, `chunks`, `matchKeys`, `matchPhrase`, `isValidNumber`, `getRandomInt`, `sleep`, `codes` (HTTP messages), `fontRx`/`matroskaRx`/`matchFontFiles`/`matchSubtitleFiles`.
- **`networking.js` (308)** — `status` writable (`'online'|'offline'|…`), `printError`, `isOffline`/`isAnilistDown` outage checkers (debounced/backoff via `newOutageChecker`), external-fetch wrapper, ping `https://cp.cloudflare.com/generate_204`.
- **`navigation.js` (641)** — `page` and `modal` state machines (HOME/PLAYER/SEARCH/SETTINGS/WATCH_TOGETHER/TORRENT_MANAGER; modals ANIME_DETAILS/TORRENT_MENU/…), `playPage`, `drawerOpen`; deep-link entry points.
- **`protocol.js` (71)** — `zero://` and `magnet:` routing; registers `onTorrentRequest`, `onProviderToken`, `onRequestPage`, `onRequestModal`, `onRequestPlay`, `onLobbyInvite`.
- **`sections.js` (418)** — home-rail definitions/`SectionsManager`, search state store (`search`, `key`, `hasNextPage`), `lastSearched` history; subscribes to `swrRevalidated`.
- **`rss.js` (259)** — `RSSManager` (`getMediaForRSS`, `getContentChanged`, `findNewReleasesAndNotify`, `structureResolveResults`), RSS→media resolution for home feeds, cached in `QUERY_RSS`. Feeds are nyaa/sukebei (base64'd).
- **`episodes.js` (153)** — `episodesList`, MAL episode metadata via **Jikan** `https://api.jikan.moe/v4/anime/{id}/episodes` and Kitsu `https://kitsu.app/api/edge/anime/{id}/episodes`, with a `Bottleneck` limiter (60/min, 3 concurrent, minTime 333ms) and retry-after handling.
- **`torrent.js` (197)** — the torrent UI projection + **the play entry point** (`add`, `stage`, `unload`, `untrack`, `complete`); stores `loadedTorrent`, `stagingTorrents`, `seedingTorrents`, `completedTorrents`, `loadingSession`.
- **`subtitles.js` (336)**, `themes.js`, `graphics.js`, `banner.js`, `preload.js`, `reachability.js`, `support.js` (`SUPPORTS.isAndroid` etc.).

### `modules/anime/`
| File | Role | External APIs | Cache |
|---|---|---|---|
| `anime.js` (1074) | The anime domain hub. `play/handlePlay/playMedia/playAnime`, `handleAnime`, `traceAnime(image)`, `getChaptersAniSkip`, `getMediaMaxEp`, `anitomyscript` (filename parsing wrapper), `hasZeroEpisode`, `getEpisodeMetadataForMedia`, `setStatus`, `isSubbedProgress`, `getKitsuMappings`, `getAniMappings`; maps: `durationMap`, `formatMap`, `statusColorMap`, `genreIcons`, `genreList`, `tagList` | `https://api.ani.zip/mappings?anilist_id=`, `https://kitsu.app/api/edge/mappings?filter[externalSite]=anilist/anime&filter[externalId]=…&include=item`, `https://api.aniskip.com/v2/skip-times/{idMal}/{ep}/?episodeLength=…&types=op&types=ed&types=recap`, `https://api.trace.moe/search` | `QUERY_MAPPINGS` (SWR, 120d) |
| `animeresolver.js` (694) | Filename → AniList media. `resolveFileAnime`, `findAnimesByTitle`, `alternativeTitles`, `cleanFileName`, `isVerified`, `resolveSeason`/`resolveBySeason`, `findPrequel`, `handleEpisode`, `findEdge`, in-memory `animeNameCache`. Season/absolute-episode offsetting lives here | AniList compound search | `QUERY_COMPOUND` (SWR, 7d) |
| `animeprogress.js` (80) | Per-episode watch position. `setAnimeProgress({name,mediaId,episode,currentTime,safeduration})`, `getAnimeProgress`, `liveAnimeProgress(mediaId)` (derived %/episode), `liveAnimeEpisodeProgress`, `resetAnimeProgress` | none | `HISTORY:animeEpisodeProgress` |
| `animedubs.js` (79) | `malDubs` — dubbed/incomplete MAL id lists, hourly refresh; `isDubMedia` also does filename phrase matching (Dual Audio / English Dub) | `https://raw.githubusercontent.com/MAL-Dubs/MAL-Dubs/main/data/dubInfo.json` | GENERAL |
| `animeschedule.js` (464) | Airing schedule + dub schedule feeds, hero images | `https://raw.githubusercontent.com/RockinChaos/AniSchedule/master/raw/{feed}.json` | own store |
| `animehash.js` (132) | Info-hash ↔ (mediaId, episode) memory: `setHash`, `getHash`, `getId`. How a torrent is re-identified across sessions | — | `HISTORY` |

### `modules/debrid/`
- **`availability.js` (162)** — pure vocabulary. `Availability = {CACHED, AVAILABLE, UNAVAILABLE, UNKNOWN}`; `AVAILABILITY_ORDER`; `AVAILABILITY_TTL` = cached 6h, available 20m, unavailable 30m, unknown 0; `normalizeAvailability`, `streamsInstantly` (== CACHED), `availabilityOf(map, hash)` (lowercase hash keys), `preferCached(results, map)`, `describeAvailability`, `outageNotice(error, title)`.
- **`route.js` (102)** — pure policy. `routeDebrid({torrentID, hash, serviceSelected, serviceReady, offline, mode})` → `{action:'torrent'|'block'|'resolve', reason?:'key'|'offline'|'source', id?, only}`. `debridKey(settings, service)` (one key per service). `listResult(result, availability, {cachedOnly, only})`. `createListResults()` — identity-stable split into listed/hidden + counts + `cachedKey`.
- **`debrid.js` (548)** — the UI-facing surface. Stores: `debridEnabled`, `debridTransport` (`{title, only, checksAddMagnets, label, description}`), `debridAvailability` (Map hash→state), `debridChecking`, `debridReleaseNames`, `debridPlayback`, `debridStatus`, `debridOptions`. Functions: `streamDebrid(torrentID, hash, search, {current})` (returns `true` = handled), `resolveDebridFiles`, `replayDebridPlayback`, `testDebrid`, `refreshDebridAvailability` (≤1/min), `checkDebridAvailability(results)`, `cancelDebridAvailability`, `boundedDebridPlay` (`DEBRID_PLAY_DEADLINE_MS = 30_000`), `QUEUE_WINDOW = 50` ms answer coalescing. Generation counters (`playbackGeneration`, `availabilityGeneration`) guard against out-of-order network completions.
- **`metadata.js` (628)** — `DebridMetadata`: Matroska parsing over HTTP Range for a *remote* file (`RemoteFile.slice()` → `bytes=start-end`), streaming subtitles/chapters/attachments/fonts from a debrid URL. Constants: `AHEAD_SECONDS=120`, `JUMP_BACK_SECONDS=15`, `RETRIES=3`, `MAX_ANDROID_FONT=15MB`, `FIRST_READ_CUE_WAIT=2500`, `HEADER_READ_CAP=256MB`, `TARGETED_READ_CAP=64MB`. **In Flutter this whole module disappears** — libmpv/libass reads its own container.

### `modules/extensions/`
- `manager.js` (953) — `extensionManager` singleton (see §5).
- `handler.js` (401) — `getTorrentResults({media, episode, batch, movie, resolution})`, `queryExtensions`, `ALToAniDB`/`ALtoAniDBEpisode` mapping, `createTitles`, `dedupe`, `updatePeerCounts`, codec `exclusions` probe (skipped when `capabilities.native_media_stack`).
- `worker.js` (205) — the comlink-exposed Web Worker sandbox.
- `transport.js` (80) — `requestVia(url, options, {hostRequest, fetch, blocked})`, `normalizeMethod`, `headersOf`. Host-native HTTP when available, `fetch` otherwise; private/local address refusal both before the request and after redirects.

### `modules/lib/` (pure, test-covered helpers — the easiest 1:1 Dart ports)
`deadline.js` (`SOURCE_DEADLINE = 45_000`, `withDeadline`), `single-flight.js` (`createSingleFlight`), `retry.js` (`RATE_LIMIT_RETRIES=3`, `ERROR_RETRIES=1`, `retryWorthwhile`), `diagnostics.js` (console→host log forwarding: `FLUSH_DELAY=300`, `MAX_BATCH=100`, `MAX_MESSAGE=2000`, `redact()` for signed URLs/tokens, `createForwarder`, `attachDiagnostics`), `introspection.js` (`serviceVerdict`, `LOG_PRESETS`), `image-store.js` (`IMAGE_STORE_BYTE_LIMIT=160MB`, `IMAGE_FETCH_CONCURRENCY=12`, `pin/isHeld/heldStats/releaseAll`), `image-memory.js` (`IMAGE_MEMORY_LIMIT=4000`, `rememberShown/wasShown/imageSignature`), `media-probe.js`, `progressive.js` (`firstPaintAt`), `torrent-toasts.js` (`torrentToast(type,{toasts,debridActive})` — torrent failures stay silent while debrid owns playback), `haptics.js`, `clipboard.js`, `asset.js`, `debug.js` (vendored `debug`). **DOM-only, do not port**: `click.js` (584 — svelte actions), `hover.js`, `preload.js`.

### `modules/notification/`
- `manager.js` (84) — `localNotifications` store, `unreadCount` derived → `DESKTOP.setUnreadCount`, debounced batching (`processNotifications` 15s, `markWatchedAsRead` 2.5s, persist 1.5s), system notifications dispatched via `COMMON.notify` staggered 5ms apart, `readNotification()`.
- `util.js` (170) — pure: `sort`, `filter`, `dedupe`, `upsert`, `markAsRead`, `splitLocalAndSystem`, `getFlags(notification, media)`.

### `modules/playback/` (all pure/testable except where noted — these encode hard-won bug fixes; port the *rules*, drop the HTML-video mechanics)
| File | Keep in Flutter? | Content |
|---|---|---|
| `request.js` | **Yes, critical** | `playRequest` store, `requestPlayback(search)`, `matchRequestedFile(files, request)`, `describeMissingEpisode()`. Explicit episode request outranks the watch-status guess |
| `coverage.js` | **Yes** | `releaseHoldsEpisode(parseObject, {episode, absoluteEpisode, episodeCount})` — a title naming 2 episodes is not a batch |
| `probe.js` | **Yes** | `PROBE_TIMEOUT_MS=6000`, `PROBE_RETRY_DELAY_MS=1500`, `PROBE_BYTES=262144`, `probeTarget`, `bustedUrl`, `probeStream` (open-ended `bytes=0-`, must receive 256KB), `verifiedStream` (2 attempts) |
| `resume.js`, `prompts.js`, `quiet-start.js`, `stall.js`, `buffering.js`, `first-frame.js`, `errors.js`, `loading-screen.js`, `thumbnails.js` | Rules yes, mechanics no | resume points, autoplay prompts, "nobody touches the stream before first frame", stall watchdog (15s window), spinner state machine, startup timing, error-worth-showing filter |
| `audio.js`, `subtitle-select.js`, `subtitle-scheduler.js`, `cue-index.js`, `mkv-header.js`, `mkv-subtitles.js`, `transport.js` | **No** | HTML-video/JASSUB/WebKitGTK-specific; libmpv+libass replaces all of it. `subtitle-select.js`'s single-decision rule is worth preserving as policy |

### `modules/providers/`
See §3.

---

## 3. AniList / MyAnimeList integration

### Auth
- **AniList** (`modules/settings.js` + `providers/anilist/anilist.js`): implicit-grant. Host opens the browser (`COMMON.openURI`/`linkAccount`); the token returns via `zero://` protocol (`onProviderToken`) **or** by the user pasting the redirect URL (a global `paste` listener parses `access_token=…&token_type`). Token stored in `localStorage['ALviewer']` as `{token, expires_in, reauth, viewer}`. No refresh exists — expiry is set to **now + 335 days** (≈1 month before AniList's ~12mo), `validateToken()` marks `reauth` and toasts "Login Expiring"/"Expired" (hard expiry = `expires_in + 30d`).
- **MyAnimeList** (`providers/myanimelist/myanimelist.js`): OAuth2 PKCE, `client_id` base64'd in source (`bb7dce3881d803e656c45aa39bda9ccc`, app type "other", plain code_verifier stashed in `sessionStorage[state]`). Token exchange `POST https://myanimelist.net/v1/oauth2/token` (`authorization_code`, then `refresh_token`). Stored in `localStorage['MALviewer']` as `{token, refresh, refresh_in, reauth, viewer}`; `refresh_in` = **now + 14 days**; `refreshMalToken()` handles rotation, failure sets `reauth`.
- **Multi-profile**: `profiles` store (localStorage), `swapProfiles()` moves the active viewer in/out, `cache.abandon(viewerId)` re-points the user IndexedDB, then `location.reload()`. `sync` store lists profile ids that receive mirrored writes.

### AniList operations (`anilist.js`, 1148 lines; `alRequest()` → `POST https://graphql.anilist.co`)
Queries/mutations by method, with cache store and TTL:

| Method | Store | Expiry |
|---|---|---|
| `viewer({token})` | — | — |
| `getUserLists({userID, token, sort})` (MediaListCollection) | `USER_LISTS` | 14 min (re-cached by a 15-min interval) |
| `getNotifications` / `findNewNotifications` (related airing) | `QUERY_NOTIFICATIONS` `'anilist_related_airing'` | 4 min (5-min interval) |
| `alSearchCompound(flattenedTitles)` (batched title→id) | `QUERY_COMPOUND` | random 60–90 min |
| `search(variables)` (Page media) | `QUERY_SEARCH` | random 75–100 min |
| `searchIDSingle` / `searchIDS` | `QUERY_SEARCH_IDS` | 80–100 min / 24–30 min |
| `searchAllIDS` (paged sweep) | `QUERY_SEARCH_IDS` | 34–46 min |
| `episodes({id})` / `episodeDate` (airingSchedule) | `QUERY_EPISODES` | 75–100 min / 90–100 min |
| `following(variables)` | `QUERY_FOLLOWING` | 200–300 min |
| `recommendations({id})` | `QUERY_RECOMMENDATIONS` | 1500–2000 min |
| `favourite`, `reviews`, `title`, `requestMediaID`, `fallbackSearch` | — | — |
| **Mutations**: `entry(variables)` (SaveMediaListEntry), `delete`, `updateListEntry`, `deleteListEntry` | optimistic patch into `USER_LISTS` via `#applyEntry` | — |

Media fragment requests `customLists(asArray: true)` and `score(format: POINT_10)`. Offline behaviour: every read does `cachedEntry(store, key, offline)` first — offline ignores expiry.

### MyAnimeList operations (`myanimelist.js`, 384 lines; `malRequest()` → `https://api.myanimelist.net/v2/{path}`)
- `viewer(token)` → `GET users/@me`
- `getUserLists()` → `GET users/@me/animelist?fields=…&nsfw=true&limit=&offset=&sort=` (paged)
- `entry(variables)` → `PATCH anime/{idMal}/my_list_status`
- `delete(variables)` → `DELETE anime/{idMal}/my_list_status`
- `malEntry(media, variables)`, `refreshToken(query)`, `#flushMutationQueue()`
Status mapping lives in `cache.js:1432` (`watching→CURRENT`, `plan_to_watch→PLANNING`, `completed→COMPLETED`, `dropped→DROPPED`, `on_hold→PAUSED`, `is_rewatching→REPEATING`); sort mapping in `Helper.sortMap`.

### Mutation queue (`providers/lib/mutationqueue.js`, 269)
Persisted in `GENERAL:syncQueueAni` / `syncQueueMal`. Types `entry|delete|favourite`. Rate limits: **AniList 8/min, 500 ms spacing; MAL 30/min, 1500 ms** (tightened to **15/min, 3000 ms** when MAL is the authenticated provider). Duplicate favourite toggles cancel; duplicate entry/delete are last-write-wins preserving original `progressBefore`/`queuedAt`. `progressBefore` powers stale-write detection. Queued mutations flush on reconnect (`status` subscription in `anilist.js:245`) and after `userLists` settle. Tokens are stripped from persisted variables and replaced with `tokenUserId`.

### Sync rules — when a watch counts (`routes/player/PlayerPage.svelte:1866` + `providers/helper.js:154`)
1. Threshold: `currentTime >= safeduration * (settings.playerAutocompleteThreshold / 100)`, default **85%**, gated by `settings.playerAutocomplete`. **If an external player is used, the threshold is clamped to 0.7** (accommodates OP/ED skipping). Fires once per file (`completed` latch).
2. Also requires `media.media.episodes` to exist, or `nextAiringEpisode.episode >= (episodeRange.last || episode)`.
3. For batched files, the *last* episode of `episodeRange` is what gets written.
4. `Helper.updateEntry(filemedia)` then applies the real rules:
   - refuses if the file failed to resolve (`failed`) → toast "Failed to Update Progress";
   - refuses if `cachedMedia.status === 'CANCELLED'`;
   - `videoEpisode = (episode || singleEpisode) + (zeroEpisode ? 1 : 0)` — zero-episode shows are offset by one; `singleEpisode` covers movies/1-ep OVAs;
   - refuses if `videoEpisode > getMediaMaxEp(cachedMedia)`;
   - **refuses if `progress > videoEpisode`** (never move backwards);
   - **refuses if `progress === videoEpisode` and it is not the final episode and not a single-episode work** (no redundant writes);
   - status becomes `REPEATING` if it already was, else `CURRENT`; becomes `COMPLETED` when `videoEpisode === mediaEpisode` and the show is not `NOT_YET_RELEASED`, incrementing `repeat` on a rewatch completion;
   - `getFuzzyDate` fills `startedAt` (on CURRENT/REPEATING) and `completedAt` (on COMPLETED);
   - the mutation is only sent if status, progress, score, or repeat actually changed;
   - score is `*10` for AniList (POINT_10 → POINT_100), raw for MAL;
   - on success: `readNotification({id, episode, episodes})`, `resetAnimeProgress(mediaId)` when a new rewatch starts, `listToast`, and the same write is mirrored to every profile listed in `sync` (per-profile custom-list lookup for AniList).

---

## 4. Playback resolution flow — click to URL

```
Episode card click
  └─ anime.js: play(media, episode) / handlePlay(id, episode, torrentOnly)
       desired episode = explicit episode, else mediaListEntry.progress + 1
  └─ TorrentModal.playAnime(media, episode, force)
       └─ findInCurrent({media, episode}) hits? → page.navigateTo(PLAYER), done (already loaded)
       └─ else modal.open(TORRENT_MENU, {media, episode})

TorrentResults.svelte
  1. resolution = settings.rssQuality ('2160'|'1080'|'720'|'540'|'480'|'')
  2. getTorrentResults({media, episode, batch, movie, resolution})   [extensions/handler.js]
       - AniList id → AniDB/TVDB/IMDB/TMDB mappings (api.ani.zip, kitsu)
       - builds TorrentQuery {anilistId, titles[], season, absoluteEpisode, before/afterSeason,
         before/afterEpisode, episodeCount, resolution, exclusions[], isAndroid}
       - fans out to every enabled extension worker: source.single(), + .movie() if movie, + .batch() if batch
       - dedupe → anitomyscript() parse of every title
       - releaseHoldsEpisode() drops releases whose titles say they lack the episode
       - updatePeerCounts(): tracker scrape via TORRENT.scrape, SKIPPED when debrid is enabled
         or torrentAutoScrape is off (a scrape is 15s/source of pure wait)
  3. Debrid availability: debounce(250ms) → checkDebridAvailability(hashes)
       DEBRID.watchAvailability(service, key, hashes, requestId) → 'availability' events
       coalesced in a 50 ms QUEUE_WINDOW into the debridAvailability Map
  4. createListResults(): split into results/hiddenResults + per-state counts + cachedKey
       listResult(): cachedOnly ⇒ only CACHED; debrid-only ⇒ hide UNAVAILABLE;
                     otherwise seeders > 0 || source.managed || cached
  5. getBest(search, results, audioLanguage, torrentProvider):
       candidate tiers — exactBest (exact audio match & seeders > 9), exactAlt,
       dualBest (audio match & seeders > 1), dualAlt, plus source-typed 'best'/'alt' with seeders > 9;
       when debrid is enabled the candidate list is passed through preferCached() first
       (a most-seeded release the service does not hold is a guaranteed resolve failure)
  6. autoPlay(best) if settings.rssAutoplay (5 s countdown), else user clicks a card
  7. play(result): remembers HISTORY:lastMagnet[mediaId][episode|'batch'],
       then add(result.link, {media, episode}, result.hash)
```

```
torrent.js add(torrentID, search, hash)                       ← the single funnel
  - single-flight key `${torrentID|hash}:${episode}`; playGeneration++ for ordering
  - files.set([]); page.navigateTo(PLAYER); nowPlaying = {media, episode, torrent|feed}
  - requestPlayback(search)              → playRequest store (explicit episode wins later)
  - setHash(hash, {mediaId, episode})    → hash↔episode memory
  - Android + !enableExternal → requestFullscreen()
  - handled = await streamDebrid(torrentID, hash, search, {current})
  - if (!handled) TORRENT.stream(torrentID)        ← torrent lane
  - if (handled && files empty) navigate back (nothing is coming)

streamDebrid  [debrid/debrid.js]
  route = routeDebrid({torrentID, hash, serviceSelected, serviceReady, offline, mode})
    no service            → {action:'torrent'}                    → torrent lane
    no key / offline / unresolvable id
       prefer mode        → {action:'torrent'}                    → torrent lane
       only mode          → {action:'block', reason:'key'|'offline'|'source'} → toast, nothing plays
    otherwise             → {action:'resolve', id}
  debridPlayback = true (claimed BEFORE the resolve — the player is already open)
  debridStatus = "Resolving cached release with <service>…"
  boundedDebridPlay(resolveDebridFiles(...), 30 s deadline)
     DEBRID.resolve(service, key, magnet, episode)  → {hash, name, files[], target}
        on kind==='timeout' exactly one retry (the core is in short-probe recovery mode)
     probeTarget(files, target) → the file the SERVICE picked (pack files land on different CDN nodes)
     verifiedStream(url): probe bytes=0- until 256 KB, 6 s timeout, one retry after 1.5 s
        dead → DEBRID.forgetResolved(service, key, hash)   (links are pinned per file, never reissued)
     publishAvailability([[hash, CACHED]])   ← playing it is the most authoritative answer
  files.set(resolved)  IMMEDIATELY (probe runs in parallel with filename parsing/episode matching)
  await verified → if !alive: files.set([]) and throw {kind:'link-dead'}
  catch:
     kind 'rejected'  → "Wrong Release" toast, handled=true, NO torrent fallback
     provenAvailability(error): 'not-cached'→AVAILABLE, 'unavailable'→UNAVAILABLE
         → recordAvailability(); prefer mode → toast + fall back to torrent; only mode → error
     anything else    → prefer mode → warn + torrent; only mode → error toast
  All of this is guarded by playbackGeneration — a late completion can never own the player.

Files land (either lane) → MediaHandler.svelte handleFiles(files, targetFile)
  - cleanFiles / sortFiles
  - matchRequestedFile(files, playRequest)  ← explicit request wins
  - else findPreferredPlaybackMedia(): currently-watching ⇒ progress+1, else lowest unwatched present
  - describeMissingEpisode() explains a release that provably lacks the episode
  - AnimeResolver.resolveFileAnime(fileName) attaches media/episode/episodeRange per file
  - checkForZero(media) applies the zero-episode offset
  - nowPlaying set → PlayerPage

PlayerPage.svelte:361   src = file.url        ← the player finally has a URL
  - torrent lane: url is the Rust loopback HTTP Range gateway
  - debrid lane:  url is the provider's direct CDN link
  - TORRENT.setPlayback(current, external) tells the engine which file is open
  - external mode: TORRENT.launchExternal(current) (mpv fed a signed URL over stdin)
  - on mid-stream death: bustedUrl(url, ++streamNonce) re-open, then replayDebridPlayback()
    (re-runs the whole routing decision rather than reloading a dead address)
```

**Quality handling**: a single global `settings.rssQuality` is passed to sources as `resolution`; changing it re-queries the sources (it is a different question, not a filter). `settings.audioLanguage` and `subtitleLanguage` drive the `getBest` audio tiers and track selection. `settings.torrentSort` (`seeders|best|batch|size|date`) sorts the list.

---

## 5. Extensions system (JS worker sandbox — replaced by declarative manifests in Flutter)

**Loading** — `modules/extensions/manager.js` (`extensionManager`, 953 lines):
- Schemes: `VALID_SCHEMES = /^(https?:|gh:|npm:|file:|extension:)/`, `CUSTOM_SCHEMES = /^(gh|npm):/`. `gh:user/repo[/path]` and `npm:pkg` are rewritten to `https://esm.sh/gh/...` / `https://esm.sh/...` (with `/es2022/....mjs` fallbacks); local paths become `extension://…`.
- A repository manifest is an `index.json` array of `SourceConfig` (or `RepositoryConfig` with just `main`). Config validation: `validateConfig()`.
- Key API: `addSource(url)`, `removeSource(id)`, `updateSources(url)`, `checkForUpdates()` (SemVer), `loadExtensions()`, `reloadExtensions()`, `enableExtension/disableExtension`, `validateExtension(key)`, `getExtensionCode(key, worker)`, `updateExtensionSettings(key)`, `whenExtensionReady(key)`, `whenReady` deferred (a generation token — a reload invalidates in-flight loads), `isPrivateOrLocal(url)` (SSRF guard), `portMessage(event, worker)` (main-thread fetch proxy for workers).
- Persistence: `caches.EXTENSIONS` (shared DB) — `extensionSources`, `repositorySources`; user selection/settings in `settings.extensionsNew`.

**Execution** — one Worker per extension over **comlink**:
- `initialize(id, type, module, {settings, bypassCORS})`; `anitomyscript` injected onto the source; `source.settings` from user config. `isStubModule()` rejects re-export-only modules.
- CORS: `source.validate()` with plain fetch; on failure `globalThis.fetch` is swapped for a postMessage bridge to the main thread routed through `transport.js` → `COMMON.request` (host-native HTTP). Redirect destinations re-checked against the private-address rule.
- `query(options, {movie, batch}, online, {enabled})`: **90-second in-worker result cache** keyed by `JSON.stringify({options,types})`; served regardless of age when offline. Calls `source.single()` always, plus `.movie()` and `.batch()` per query type, via `Promise.allSettled`. Whole-worker query budget `SOURCE_DEADLINE = 45_000`.
- `updateSettings(settings)` clears the cache; `terminate()` aborts via AbortController.

**What a source is** — `frontend/extensions/sources/abstract.js` + `frontend/extensions/index.d.ts`:
```ts
class TorrentSource { single(q); batch(q); movie(q); validate(): Promise<boolean> }
```
Each search returns `TorrentResult[]`:
`{ title, link, hash, size, seeders, leechers, downloads, date, id?, accuracy?: 'high'|'medium'|'low', type?: 'batch'|'best'|'alt' }`
Input `TorrentQuery`: `{ anilistId, media, mappingsA, mappingsE, anidbAid, anidbEid, tvdbAid, tvdbEid, imdbAid, mvdbAid, titles[], episode?, episodeCount?, resolution, exclusions[] }`.
Manifest `SourceConfig`: `{ id, name(≤16), version(semver), main, update ('gh:'|'npm:'|URL, or an array of fallbacks), nsfw?, unregulated?, type:'torrent', speed, accuracy, settings?: SourceSetting[], deprecated?, description?(≤500), icon? }`. `SourceSetting` kinds: `text` (secret/required/placeholder/default), `toggle`, `dropdown`, `multiselect` — surfaced in the Extensions settings tab and passed back as `this.settings`.
Example/dummy source: `frontend/extensions/sources/example.js`, index at `frontend/extensions/index.json`.

**Flutter implication**: no arbitrary remote ESM in Dart — the declarative source format replaces it. The `TorrentQuery`/`TorrentResult` shapes and the 90 s cache / 45 s deadline / private-address guard are kept verbatim.

---

## 6. Settings

Single flat object, `defaults` at `frontend/common/modules/util.js:684`, stored at `caches.GENERAL:'settings'`. `homeSections` is a *scoped* default recomputed from `rssFeedsNew` + `customSections`. Profiles/tokens live in `localStorage`, not here.

| Group (settings tab) | Keys |
|---|---|
| **App** (`AppTab`) | `updateChannel` ('stable'\|'nightly'), `updateVersion`, `closeAction` ('Prompt'), `offlineSync` (true), `queryComplexity` ('Complex'), `toasts` ('All') |
| **Interface** (`InterfaceTab`) | `presetTheme` ('default-dark'), `customCSS`, `uiScale` (1), `cards` ('small'), `cardPreview` (true), `cardAudio` (false), `toggleList`, `titleLang` ('romaji'), `hideMyAnime` (false), `showLabels` (true), `expandingSidebar` (false), `homeSections`, `customSections`, `rssFeedsNew`, `preferDubs` (false), `adult` ('none'), `hentaiBanner` (false), `spoilers` ('off'), `spoilerStatus` ([]), `systemNotify` (true), `aniNotify` ('all'), `rssNotify` (['CURRENT','PLANNING']), `releasesNotify` ([]), `subAnnounce`/`dubAnnounce`/`hentaiAnnounce` ('none'), `enableRPC` ('full'), `donate` (true), `w2g` (false) |
| **Player** (`PlayerTab`) | `volume` (1), `playerAutoplay` (true), `playerPause` (true), `playerAutocomplete` (true), `playerAutocompleteThreshold` (85), `playerDeband` (false), `playerSeek` (2), `playerSkip` (false), `playerTitleTop` (true), `playerCoverVideo` (false), `playerChapterSkip` ('embedded'), `playerPath` (''), `enableExternal` (false), `subtitleLanguage` ('eng'), `subtitleRenderHeight` ('720' Android / '0'), `disableSubtitleBlur` (Android), `audioLanguage` ('jpn'), `missingFont` (true), `font`, `disableMiniplayer` (false), `autoHideMiniplayer` (true) |
| **Client / torrent** (`ClientTab`) | `torrentSpeed` (5 MiB/s → bytes), `torrentPersist` (false), `torrentDHT`/`torrentPeX`/`torrentUTP` (false, **inverted** when sent to the engine), `torrentPort` (0), `dhtPort` (0), `maxConns` (50), `seedingLimit` (5 desktop / 2 Android), `torrentPathNew`, `torrentStreamedDownload` (true), `disableStartupTorrent` (Android), `configTrackers` (false), `trackers` (15 base64'd udp/http/wss announce URLs), `extensionsNew` |
| **Extensions / sources** (`ExtensionTab`) | `extensionsNew` ({}), `torrentProvider` ([]), `rssQuality` ('1080'), `rssAutoplay` (true), `rssAutofile` (true), `torrentSort` ('seeders'), `torrentAutoScrape` (true), `audioLanguage`, `adult` |
| **Debrid** (`DebridTab`) | `debridService` ('none' \| alldebrid\|premiumize\|realdebrid\|torbox), `debridApiKeys` ({} — one key per service so switching never loses one and no key reaches another service's API), `debridMode` ('prefer'\|'only'), `debridCachedOnly` (false), `debridCacheCheck` (true) |
| Not in a tab | `debugStore` (separate persisted store, key `debug`) |

Other persisted state that is **not** settings: `GENERAL` → `sync`, `syncQueueAni`, `syncQueueMal`, `loadedTorrent`, `stagingTorrents`, `seedingTorrents`, `completedTorrents`, `posMiniplayer`, `widthMiniplayer`; `HISTORY` → `lastMagnet`, `lastBoosted`, `lastSubtitle`, `lastSearched`, `animeEpisodeProgress`; `NOTIFICATIONS` → `notifications`, `incomingNotifications`.

---

## Porting priority (suggested)

1. **Pure, already-testable** (direct Dart ports, existing tests in `frontend/test/unit/` become the spec): `debrid/route.js`, `debrid/availability.js`, `playback/request.js`, `playback/coverage.js`, `playback/probe.js`, `notification/util.js`, `lib/{deadline,single-flight,retry,diagnostics,torrent-toasts,progressive,introspection}.js`.
2. **Ports/interfaces**: bridge.js contract → Dart abstract classes + streams.
3. **Stateful services**: `cache.js` (→ sqlite + an SWR wrapper), `settings.js`, `providers/*` (+ `mutationqueue.js`), `anime/*`, `debrid/debrid.js`, sources.
4. **Drop entirely**: `debrid/metadata.js`, `subtitles.js`, `playback/{mkv-*,cue-index,subtitle-scheduler,transport,audio}`, `lib/{click,hover,image-store,image-memory,preload}`, `graphics.js`.
