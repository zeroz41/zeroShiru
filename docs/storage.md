# Local storage

Zero asks `path_provider` for two separate roots and never constructs a home
directory path itself:

- **Application support** contains data the app or user expects to survive
  cache cleanup.
- **Application cache** contains data that Zero can fetch or rebuild again.

## Layout

| Data | Root | Relative path | Why |
|---|---|---|---|
| settings and other profile state | support | `db/profile-default.db` | durable user-owned state |
| installed JMdict dictionary | support | `db/learning.db` | an explicit, potentially large user download |
| application log | support | `main.log` | retained for diagnostics and user export |
| credentials and tokens | OS credential store | managed by `flutter_secure_storage` | secrets do not belong in SQLite or plain files |
| shared HTTP/query cache | cache | `db/shared.db` | rebuildable from upstream services |
| fetched Jimaku subtitles | cache | `learning-subtitles/` | rebuildable downloaded artifacts |

Typical roots for the current application identifiers are:

| Platform | Application support | Application cache |
|---|---|---|
| Linux | `${XDG_DATA_HOME:-~/.local/share}/dev.zeroz.zero` | `${XDG_CACHE_HOME:-~/.cache}/dev.zeroz.zero` |
| Windows | `%APPDATA%\dev.zeroz\Zero` | `%LOCALAPPDATA%\dev.zeroz\Zero` |
| macOS | `~/Library/Application Support/dev.zeroz.zero` | `~/Library/Caches/dev.zeroz.zero` |
| Android | `/data/user/0/dev.zeroz.zero/files` | `/data/user/0/dev.zeroz.zero/cache` |

Sandboxing, alternate XDG variables, and OS-managed containers can change the
physical prefix. `path_provider` remains the source of truth on every platform.

## Upgrade migration

Releases made before the cache split stored `db/shared.db` and
`cache/learning-subtitles/` below application support. On the first launch with
the new layout, Zero migrates those files before opening either cache:

- a cache already present in the new location wins a conflict;
- subtitle directories are merged without overwriting current entries;
- the SQLite main file and its WAL/SHM sidecars move as one family;
- repeat launches are safe, including after a partially completed migration;
- migration errors are logged but do not prevent startup, because both stores
  are disposable and can be rebuilt.

The profile database, installed dictionary, log, and credentials are not part
of this migration.

## Cache lifetime

The application-cache root is persistent across ordinary launches; Zero does
not clear it at startup or shutdown. The OS or user may still remove it under
storage pressure or through a cache-cleaning action, which is why only
rebuildable data belongs there.

Metadata expiry is a freshness deadline, not an immediate deletion deadline.
AniList search results, media details, recommendations, and airing metadata use
stale-while-revalidate behavior:

- a fresh entry is returned from SQLite without a network request;
- an expired entry is still returned immediately while one background refresh
  for that cache key runs;
- a failed refresh leaves the stale entry available for the next launch;
- a changed response replaces the stored entry and resets its measured TTL;
- per-store entry caps prune the oldest keys instead of clearing the database.

Account-owned lists do not serve stale data while online because progress and
list state must reflect recent mutations. They remain available past expiry
when Zero is offline.
