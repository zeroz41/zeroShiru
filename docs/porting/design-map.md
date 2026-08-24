# zeroShiru → Flutter DESIGN PORTING MAP

Surveyed from the `redo` branch (HEAD `d342051b`). Design pass reference: commit `f15bf68e` "cinema hero, accent pills, titled rails, soft posters, ambient depth". Base CSS framework was **quartermoon 1.2.3** overridden by `frontend/common/css.css`.

---

## 1. VISUAL DESIGN SYSTEM

### 1.1 CRITICAL: the rem scale is not 16px

`css.css:1-8` overrides the base font size:

```
--default-html-font-size: 48%;        /*  <1600px  → 1rem = 7.68px */
--default-html-font-size-1600: 50%;   /* ≥1600px  → 1rem = 8.00px */
--default-html-font-size-1920: 62%;   /* ≥1920px  → 1rem = 9.92px */
```

`--ui-scale` is a user setting (default 1). **Every legacy `rem` below must be multiplied by 7.68 (or 8 / 9.92) to get logical pixels.** e.g. `font-scale-24` = 2.4rem = **18.4px**; small-card poster width 19rem = **146px**; sidebar 7rem = **54px**.

The Flutter implementation treats these as the reference measurements, not a
constraint against platform readability. Its current refinement pass widens the
labelled rail to 68 logical pixels, raises the compact type/control floor, and
uses a restrained AIRING chip without the repeating poster outline. Colors,
surface hierarchy, spacing rhythm, and interaction semantics remain mapped to
this document.

### 1.2 Color palette (default-dark theme)

| Token | Value | Hex | Role |
|---|---|---|---|
| `--accent-color` | `#e5204c` | **#E5204C** | Seekbar progress + thumb only. User-overridable raw hex. |
| `--tertiary-color` | hsl(217,77%,54%) | **#2F75E4** | The real UI accent. Hero CTA, active nav pill, rail title tab, focus ring, favourite glow, ambient bloom, card hover ring. |
| `--tertiary-color-light` | hsl(217,77%,64%) | **#5D93EA** | CTA hover, rail-tab gradient top. |
| `--tertiary-color-very-light` | hsl(217,77%,79%) | **#A0C0F3** | Active nav icon color, section-title hover. |
| `--tertiary-color-dim` | hsl(217,77%,30%) | **#123F87** | Link hover. |
| `--highlight-color` | `#FFFFFF` | **#FFFFFF** | On-accent text, active nav label. |
| `--dark-color` | hsl(220,10%,10%) | **#17191C** | Page base. |
| `--dark-color-light` | hsl(220,10%,14%) | **#202327** | Panels, toast bg. |
| `--dark-color-very-light` | hsl(220,10%,16%) | **#25272D** | Raised inputs, hover. |
| `--dark-color-dim` | hsl(220,10%,8%) | **#121416** | Shell/chrome, top of page gradient. |
| `--dark-color-very-dim` | hsl(220,10%,4%) | **#090A0B** | Modals (`bg-very-dark`). |
| `--gray-color-light` | hsl(216,10%,28%) | **#40464F** | Muted text, borders. |
| `--gray-color-very-dim` | hsl(216,5%,35%) | **#55585E** | Inactive nav icon/label. |
| `--white-color-dim` | hsl(0,0%,60%) | **#999999** | Icon hover. |
| `--white-color-very-dim` | hsl(0,0%,50%) | **#808080** | Dim icon hover. |
| `--primary-color` | hsl(209,100%,55%) | **#1A90FF** | btn-primary, dropdown checkmarks. |
| `--primary-color-light` | hsl(209,100%,65%) | **#4DA9FF** | btn-primary hover. |
| `--completed-color` | hsl(110,60%,58%) | **#69D454** | Watched/completed. |
| `--completed-color-dim` | hsl(110,60%,42%) | **#40AB2B** | Seekbar accent when episode already completed. |
| `--warning-color` | hsl(48,80%,46%) | **#D3AE17** | Warnings; w2g notice `hsla(48,80%,46%,.12)` fill. |
| `--warning-color-very-dim` | hsl(48,80%,19%) | **#57470A** | Warning alert text. |
| `--error-color` /-light /-very-light | hsl(0,89%,15/25/35%) | **#480404 / #780707 / #A90A0A** | Errors. |
| `--green-color` / `-light` | hsl(106,100%,27/40%) | **#208A00 / #30CC00** | "AIRING" badge. |
| `--octonary-color` | `#FF6B35` | **#FF6B35** | "Show My Anime" toggle, gain-boost state. |
| `--myanimelist-color` | hsl(221,57%,40%) | **#2C51A0** | MAL chrome. |
| `--anilist-color` | hsl(215,25%,21%) | **#283343** | AniList chrome. |
| Status list colors | | `--current #3DB4F2`, `--planning #F79A63`, `--paused #FA7A7A`, `--repeating #3BAEEA`, `--dropped #E85D75`, `--notify #AF68FA` | List-status dot (1.1rem circle). |

**Text on dark**: base `rgba(255,255,255,0.80)`, light `.65`, muted `.60`.

**Composite surface tokens** — port as the actual Flutter surface colors:

```
--surface-shell:         rgba(18,20,22,0.97)     /* sidebar/bottombar base */
--surface-panel:         rgba(32,35,39,0.72)     /* card/panel top of gradient */
--surface-panel-strong:  rgba(32,35,39,0.92)
--surface-border:        rgba(255,255,255,0.11)  /* every hairline in the app */
--surface-highlight:     rgba(255,255,255,0.055) /* rail-top wash */
```

**AMOLED theme**: `--accent-color #DA0101`, `--highlight-color #E0E0E0`, dark base saturation 5%, lightness ladder `0/5/8/3/4%` (true black page), white becomes `0,0%,90%`.

### 1.3 Typography

- **UI font**: `Nunito Variable` (variable weight). **Subtitles/player stats**: `Roboto`; flag emoji `Twemoji`.
- **Weights**: 300 / 400 / 500 / 600 / 700 / **900** (hero title, card titles, details H1).
- **Size ladder** (rem → px @7.68):

| Class | rem | px | Mobile (≤690px) |
|---|---|---|---|
| font-size-12 | 1.2 | 9.2 | 1.0rem |
| font-scale-14 | 1.4 | 10.8 | 1.2rem |
| font-scale-16 | 1.6 | 12.3 | 1.4rem |
| font-scale-18 | 1.8 | 13.8 | 1.4rem |
| font-scale-20 | 2.0 | 15.4 | 1.6rem |
| font-scale-24 | 2.4 | 18.4 | 1.8rem |
| font-scale-34 | 3.4 | 26.1 | 2.8rem |
| font-scale-40 | 4.0 | 30.7 | 2.4rem |
| font-scale-50 | 5.0 | 38.4 | 4.2rem |

- **Hero title**: `clamp(3.2rem, 4.5vw, 6.4rem)`, weight 900, line-height 1.06, letter-spacing −0.02em, `text-shadow: 0 0.2rem 2.4rem rgba(0,0,0,0.55)`; single-line ellipsis with `2px 2px 4px #000`.
- Card titles clamp 2 lines at line-height 1.2.

### 1.4 Corner radii

```
base:            0.6rem  (4.6px)  buttons, inputs
panel:           1.0rem  (7.7px)  toasts, panels
poster art lift: 0.9rem  (6.9px)
small card item: 1.25rem (9.6px)
brand mark:      1.35rem
pills / CTAs:    5rem    (fully round)
home-feed / results-surface top: 2.4rem 2.4rem 0 0
drawers: 0 1rem 0 0 (side), 1rem 0 0 0 (bottom)
```

### 1.5 Shadows / glows / elevation

Rationale: on a near-black page a black drop shadow is invisible, so elevation = **thin light rim + deep shadow + artwork-colored bloom**.

```
--lift-shadow:
  0 0 0 .15rem rgba(255,255,255,.22),
  0 1.2rem 2.4rem rgba(0,0,0,.75),
  0 0 3rem -.6rem var(--lift-color, transparent);

--lift-shadow-soft:
  0 0 0 .1rem rgba(255,255,255,.16),
  0 .6rem 1.4rem rgba(0,0,0,.6),
  0 0 2rem -.6rem var(--lift-color, transparent);
```

`--lift-color` is set per-card from AniList's `coverImage.color`, fallback `--tertiary-color`. **Each poster's glow is tinted by its own artwork.**

Other named shadows:
- Small card: `0 .8rem 2rem rgba(0,0,0,.22)`
- Sidebar: `1.2rem 0 3rem rgba(0,0,0,.32)`; bottombar `0 -1.2rem 3rem rgba(0,0,0,.35)`
- Home feed lip: `0 -1.2rem 3rem rgba(0,0,0,.18)`
- Brand mark: `inset 0 0 0 .1rem rgba(255,255,255,.15), 0 .8rem 2rem rgba(0,0,0,.42)`
- Hero CTA pill: `0 .4rem 1.8rem hsla(217,77%,54%,.45)`
- Active nav pill: `inset 0 0 0 .1rem hsla(tertiary,.5), 0 .5rem 1.6rem hsla(tertiary,.16)`
- Toast: `0 .8rem 2rem rgba(0,0,0,.55)`
- Favourite glow: `drop-shadow(0 0 1.2rem tertiary)` + `glow_breathe` 1s alternate infinite, opacity 1→.68.

### 1.6 Spacing & fixed geometry

Spacing ladder ≈ **3.8 / 7.7 / 11.5 / 15.4 / 19.2 / 23 / 30.7 px**.

```
sidebar width: 7rem (54px); expanded on hover: 22rem; hidden <769px
bottombar height: 7rem (mobile only, <769px)
nav button: 3.1rem; nav link height 5.5rem
statusbar: 28px; tooltip 17rem
button height 3.2rem, padding 0 1.5rem
scrollbar: 0.8rem thumb-only, radius 5rem, rgba(255,255,255,.16)→.32 hover
```

### 1.7 The poster card ("soft posters") — SmallCard

- **Container**: aspect `152/296`, width 19rem in rails, padding .65rem, border `.1rem solid var(--surface-border)`, radius 1.25rem, `background: linear-gradient(165deg, var(--surface-panel), hsla(dark,.72))`, shadow `0 .8rem 2rem rgba(0,0,0,.22)`.
- **Artwork**: aspect `230/331`, cover-fit, radius 0.9rem.
- **Hover** (pointer devices only): `translate: 0 -.5rem`, border → `hsla(217,77%,54%,.42)`, bg → `hsla(220,10%,14%,.8)`; the lift-shadow layer fades opacity 0→1 (painted once, faded — never transitioned box-shadow).
- **Press**: translate back to 0 at `--motion-press`, shadow opacity .4.
- **Focus**: ring `.25rem solid tertiary`, offset .2rem.
- **Airing**: pulsing ring, inset −1.3rem, keyframes 3.5s infinite (scale .955→1.01, opacity .9→0); green "AIRING" badge top-right (radius 1rem, font 1rem, padding .35rem .9rem).
- **Hover preview** (PreviewCard): after dwell; width `min(35rem, 90vw)`; info animates rise .25s ease-out .05s (opacity 0→1, translateY .6rem→0).
- **FullCard** = `min(52rem,88vw) × 27rem`, hover `scale 1.03`. **EpisodeCard** = 36rem wide, hover `translate 0 -.4rem`, bottom scrim.

### 1.8 Cinema hero (FullBanner)

- Frame 40rem (~307px) tall. Skeleton while loading; **keeps the last painted list** rather than reverting to skeleton on refresh.
- Layers back→front:
  1. Full-bleed image (bannerImage → YouTube trailer maxres/hq → coverImage.extraLarge → fallback), fadeIn .8s.
  2. Bottom gradient: `linear-gradient(0deg, dark 0%, dark/.75 12%, dark/.25 24%, dark/0 36%)`.
  3. Left gradient (width 80rem): `linear-gradient(90deg, dark 0%, dark/.82 42%, dark/.45 72%, transparent 100%)`.
- Content column (bottom-left, max 60rem, swipeable): hero title; meta row (format · episodes/duration · audio label · rating · season+year, `•` separated, muted); description `.line-4` clamp; genre row; **action row** (hero-cta accent pill + hero-alt ghost pill + scoring + favourite); **progress badges** — 3px tall, width 2.7rem inactive → 5rem active (width .8s ease); active bar fills via scaleX 0→1 over **15s linear**; auto-advance **15000 ms**; click/swipe resets.
- Hero data: AniList trending this season, refreshed every 5 min, only repainted if the id list changed.

### 1.9 Accent pills

| Pill | Spec |
|---|---|
| hero-cta | bg tertiary, #FFF text, radius 5rem, weight 700, shadow `0 .4rem 1.8rem hsla(217,77%,54%,.45)`. Hover: tertiary-light + scale 1.03. |
| hero-alt | bg `rgba(255,255,255,.09)`, border `.1rem rgba(255,255,255,.18)`, #FFF, radius 5rem. Hover `.16`. |
| Active nav pill | `linear-gradient(145deg, hsla(tertiary,.42), hsla(tertiary,.2))`, text tertiary-very-light, inset ring `.1rem hsla(tertiary,.5)` + glow. |
| Nav hover / press wash | `rgba(255,255,255,.10)` / `.16`, text #FFF. |

### 1.10 Titled rails (HomeSection)

- **Header**: font-scale-24 weight 700 in `--highlight-color`; hover → tertiary-very-light; click navigates to Search pre-filled with the rail's query.
- **Accent tab** before the title: `.45rem × 1.05em`, radius 5rem, `linear-gradient(180deg, tertiary-light, tertiary)`, margin-right 1rem.
- **Chevrons** (desktop): page by one viewport width, smooth, wrap at ends, 500/1000ms scroll lock.
- **Scroller**: horizontal, hidden scrollbar, drag-to-scroll (grab cursor), min-height 25rem.
- **Right fade**: 8rem wide `linear-gradient(270deg, dark 0%, transparent)`.
- **Card budget**: 50 card shells per rail; DOM never mutated during a fling; deferred load until the rail nears the viewport.

### 1.11 Ambient depth

Page background, painted once, never animated:

```css
background:
  radial-gradient(110rem 55rem at 88% -12%, hsla(217,77%,54%,0.17), transparent 62%),
  radial-gradient(80rem 55rem at 15% 112%, color-mix(in srgb, var(--accent-color) 8%, transparent), transparent 68%),
  linear-gradient(180deg, #121416 0%, #17191C 34rem);
```

Top-right tertiary bloom, bottom-left accent bloom, vertical settle dim→base over 34rem.

- `.home-feed` / `.results-surface`: top hairline border, radius `2.4rem 2.4rem 0 0`, `linear-gradient(180deg, var(--surface-highlight), transparent ~28rem)`, home adds lip shadow. Pages are transparent so the ambient wrapper shows through.
- Modal backdrop: vignette `radial-gradient(ellipse, transparent 0%, rgba(0,0,0,.85) 100%), rgba(0,0,0,.65)` — **no backdrop blur** (fragile on Linux). Blur only in tiny areas (volume OSD).

### 1.12 Navigation structure

Breakpoint **769px**: desktop = left rail (7rem), mobile = bottom bar (7rem).

- **Sidebar**: base `linear-gradient(180deg, surface-panel-strong, surface-shell)`, right hairline, shadow. Contents: back/forward arrows, brand mark (5rem, radius 1.35rem, `linear-gradient(145deg, hsla(tertiary,.3), surface-highlight)`), then nav items; tail group (notifications, settings, profile) pushed to bottom. Optional expanding mode (hover → 22rem, `--motion-panel`).
- **Bottombar**: same surfaces flipped; drawer = bottom sheet with 3.6×0.4rem grab handle.
- **Drawers**: slide `.38s cubic-bezier(.32,.72,0,1)`; backdrop `rgba(0,0,0,.45)` 200ms in / 150ms out.
- **Nav items** in order: Home, Search, Schedule, [Now Playing], [Watch Together], Downloads; tail: [Donate], Notifications, [Update], Settings, Profile. Priority map decides overflow → drawer.
- Icon scale 1.08 hover / .92 press at `--motion-press`; label below icon at font-size-12.

### 1.13 Motion constants

```
--ease-settle:  cubic-bezier(.16, .84, .34, 1)   /* fast off the mark, slow to stop */
--ease-press:   cubic-bezier(.2, 0, 0, 1)
--motion-press: 0.09s
--motion-quick: 0.12s   /* nav links */
--motion:       0.16s   /* app-wide default */
--motion-panel: 0.24s   /* sidebar width, modal open/close */
```

**Hard rules**: only opacity/scale/translate animate — never whole transforms; shadows are painted once and faded via opacity, never transitioned.

| Effect | Duration / curve |
|---|---|
| Global press | `--motion-press`, brightness .95, translateY .1rem scale .99 |
| Hover scales | button 1.04, square 1.1, switch 1.05, input 1.02, icon 1.15 at `--motion` |
| Page transition | fade 0.18s ease-out, opacity .4→1 |
| Settings tab body | fade 0.15s ease-out |
| Card entry `.load-in` | .4s ease once — translateY 1.5rem scale .98 → overshoot −0.25rem scale 1.015 @60% → rest |
| Modal | backdrop `--motion-panel`; dialog scale .95→1, origin bottom center |
| Drawers | .38s cubic-bezier(.32,.72,0,1) |
| Skeleton sweep | 1s infinite cubic-bezier(.4,0,.2,1), highlight `rgba(255,255,255,.06)` |
| Airing ring | 3.5s (small) / 7.5s (full) |
| Banner rotation / fill | 15s |
| Banner image fade-in | .8s ease |
| Preview info rise | .25s ease-out .05s delay |
| Player loading rise | .45s cubic-bezier(.25,.8,.25,1) |
| Toasts | 10s default, 2 visible, top-right |

---

## 2. SCREENS

Old navigation: page stores (home, search, schedule, settings, player, torrent_manager, watch_together) + a modal stack (ANIME_DETAILS, NOTIFICATIONS, PROFILE, TORRENT_MENU, TRAILER, FILE_MANAGER, FILE_EDITOR, MINIMIZE_PROMPT, UPDATE_PROMPT). **Home and Search stay mounted** across navigation (scroll + images preserved); others remount with the 0.18s fade.

### Home
- Cinema hero (40rem) then the lipped `.home-feed` surface with N titled rails.
- Hero: AniList trending this season (`sort TRENDING_DESC, perPage 50, onList false, season+year, not NOT_YET_RELEASED`), 5-min refresh, repaint only on id-list change.
- Rails: user-orderable/hideable. Defaults: RSS feeds (Subbed/Dubbed Releases), Continue Watching, Sequels You Missed, Planning List, Popular This Season, Trending Now, All Time Popular, custom sections.
- Interactions: rail title → search pre-filled; chevrons page; drag-scroll; card click → details; hover → preview.
- Hero: Watch/Continue/Rewatch Now (by progress/status), View Details, scoring, favourite, swipe/badge slide change.

### Search
- Sticky SearchBar over a results grid; infinite scroll with placeholder cards.
- Fields: Title, Genres/Tags (include+exclude), Season + Year, Format, Status, Sort; advanced toggle; Hide My Anime.
- Sorts: Trending, Popularity, Title, Score, Release Date; list-scoped adds Completed/Start Date, Last Updated, Progress, Your Score.
- Grid: `auto-fill minmax(16rem,1fr)` small (cap 19rem); full `minmax(min(52rem,95vw),1fr)`; episode `minmax(36rem,1fr)`.

### Schedule
- SearchPage with a schedule store: same grid, hides season/status/sort. Data from AniSchedule sub/dub feeds → AniList ids → filter to upcoming airing → sort by next airing. Live countdown per card from one shared minute tick; imminent = pulsing ring + AIRING badge. Dub mode predicts +7d (or +6y indefinite) when no future node.

### Player
See §4 below.

### Settings
- Two-pane: rail (30rem ≥993px; horizontal icon strip below) + scrolling tab body. Rail footer: version/platform/arch/session.
- Tabs: Player, Client, Interface, Extensions, Debrid, (Profiles→modal), App, Changelog, (Donate→external).
- Building blocks: SettingCard, tabs, HomeSections (drag-reorder + show/hide rails), Changelog (markdown), DiagnosticsPanel (live host health, polls only while visible).

### Downloads (was Torrent Manager)
- Sticky header: title, filter/paste input (text or magnet/.torrent adds manually), Rescan button.
- Column labels (icons below lg): Name, Size, Progress, Status, Ratio, Down/Up Speed, Seeders, Leechers, ETA.
- Groups: current, staging, seeding, completed. EmptyState when nothing; ErrorCard when filter matches nothing; warning alert at pre-download limit.

### Watch Together
- Pre-lobby: warning notice, font-scale-50 title, two 300×300 panel cards (Join Lobby / Host a Lobby).
- Lobby: chat column (grouped messages, invite, input) + 35rem user list. P2P transport; playback state broadcast from player.

### Details modal
- Full-bleed near-black modal, floating circular close (4rem) top-right.
- Blurred banner behind (opacity .5, aspect 5/1, min-height 20rem).
- Header: cover (max 50vh, audio label overlay) + title (font-scale-40, w900) + meta row (rating %, format, episodes/length, status/season/studio/genres).
- Body: description, Following (friends' scores), list-entry editor (status/progress/score/dates), collapsibles, EpisodeList (thumbnails, titles, watched state, play + search actions).
- Spoilers: `.img-spoiler` blur(1rem) brightness(.65) saturate(.4); `.text-spoiler` transparent + glow; driven by `spoilers ∈ {off,strict,hermit}`.

---

## 3. COMPONENT INVENTORY (one-liners)

AudioLabel (sub/dub/CC chip) · CustomDropdown (multi-select include/exclude) · MediaHandler (play-request resolution owner, not visual) · Menubar (desktop titlebar) · Miniplayer (floating draggable/resizable, corner snap, persisted pos/width) · Scoring · Status (network banner) · TorrentButton · Banner/FullBanner (hero) · Card dispatcher + SmallCard/FullCard/EpisodeCard/PreviewCard/EpisodePreviewCard · ErrorCard (no-results calm vs broken alarm) · EmptyState (4.8rem glyph at `rgba(255,255,255,.28)`, min-height 24rem) · ClampedNumber · ConfirmButton (two-step destructive) · SoftModal (vignette, scale .95→1) · Sidebar/Bottombar/NavBar/NavItem/NavLink · NestedDropdown (player menus) · skeletons (sweep) · Tabs · SmartImage (candidate list, identity keying, dominant-color placeholder) · modals: Minimize, Profiles, Trailer, Update, Details (+EpisodeList/Following/User), Manager (file picker), Editor (manual re-map), Notifications, Torrent (source picker + TorrentResults + TorrentCard).

---

## 4. PLAYER — features and exact constants

**Progress / completion**
- Threshold `playerAutocompleteThreshold` default **85%**; complete when `currentTime >= safeduration * (t/100)` with a frame painted and episode count known. **External-player clamp: 0.7.**
- Progress save every **10 s** while playing, plus on error. Save gate: has current data + `currentTime > 0`. Resume seeks to `max(saved - 5, 0)`.

**Seek / skip**
- Seek step `playerSeek` default **2 s**.
- Skip logic: inside non-skippable chapter >100s → +85s; inside chapter → jump to chapter end (if within 1s of media end and autoplay → next episode); `currentTime < 10` → jump to 90s; <90s remaining → jump to end; else +85s.
- `MAX_TOTAL_SKIP_TIME = 180`s: chapters longer than 3 min never auto-skippable. Adjacent skippable chapters <10s merged.
- Skippable names: Intro/Opening (op|opening|title|ncop), Outro/Ending (ed|ending|nced), Credits, Preview (preview|pv|next), Recap.
- Chapter source `playerChapterSkip ∈ {embedded, aniskip}` default embedded; AniSkip queried when no embedded chapters. Auto-skip optional; else "Skip {name}" pill bottom-right.

**Volume / rate**
- Volume step ±0.05 (keys and wheel). Gain boost unlocks after **5** up-scrolls at max, resets after 2s idle; range 0→3×. Rate `[`/`]` ±0.1 clamped 0.1–16; `\` resets; presets 0.25…8. OSD auto-hides 600ms.

**Subtitles**
- libass replaces JASSUB. Sidecar accepts `.srt,.vtt,.ass,.ssa,.sub,.txt`. Delay `,`/`.` ∓0.1s (shift ∓1.0s) + numeric input. Defaults: sub `eng`, audio `jpn`. `C` cycles tracks (…→Off→first).

**Tracks**
- Audio/video menus only when >1 track. Debrid rebuilds always request a fresh URL (dead CDN node avoidance). (The old freeze-frame canvas trick is unnecessary with libmpv.)

**Other**
- External playback (most controls hide, 0.7 clamp, play-next on completion). Fullscreen, PiP, fit toggle (cover vs best-fit), deband toggle, screenshot with subtitles, stats overlay (FPS, dropped frames, frame time, resolution, buffer health, speed, filename), Discord RPC.
- Seekbar thumbnail hover tooltip (generated thumbnails).
- Chrome auto-hide: **1.5s** playing, **5s** paused.
- Loading cover screen between episode choice and first frame: blurred banner `blur(24px) brightness(.45) saturate(1.15) scale(1.12)`, radial scrim to `rgba(0,0,0,.55)`, cover at `min(46vh,34rem)` 2:3, title + "Episode N", rise .45s.
- Prompts pause playback: "failed to identify media, fix it?" and "filler/recap, skip?".
- Recovery toasts: 8s (recovering), 30s (hard errors), 6s (generic).

**Keyboard shortcuts** (rebindable; `` ` `` opens cheat sheet)

| Key | Action |
|---|---|
| Space | Play/Pause |
| ←/→ | Seek ∓/± `playerSeek` |
| ↑/↓ | Volume ±0.05 |
| M | Mute |
| V | Gain boost toggle |
| N / B | Next / Previous episode |
| S | Skip intro / +90s |
| C | Cycle subtitles |
| , / . | Sub delay ∓0.1s (Shift ∓1.0s) |
| [ / ] | Rate ∓/± 0.1 |
| \ | Rate reset |
| F | Fullscreen |
| P | PiP |
| W | Cover/fit toggle |
| A | Deband toggle |
| O | Now Playing details |
| H | File manager |

---

## 5. Porting rules

1. **rem ≠ 16px** — multiply by 7.68/8.0/9.92 by window width, times uiScale.
2. **Two accents**: #E5204C is only the seekbar; #2F75E4 is the app's color.
3. **Elevation = rim + bloom**, bloom tinted per-poster from `coverImage.color`.
4. **Shadows never animate** — stack a pre-painted shadow layer and animate its opacity.
5. **Hover only on pointer devices** — must not exist on touch.
6. Five durations, two curves — reuse, never invent per-widget timings.
7. Home and Search stay alive across navigation; everything else remounts with a 0.18s fade.
