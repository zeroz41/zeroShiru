// The stale-while-revalidate rule in cache.js: an expired query entry answers
// immediately while the network request replaces it in the background, so a
// reload paints the same art and metadata it painted last session instead of
// blocking every rail on the network. These tests drive Cache.cacheEntry with
// hand-built stores; nothing here touches IndexedDB (the writers only reach it
// through subscribers that never attach outside the app).
import { describe, it, expect } from 'bun:test'

// cache.js opens its databases at import; an open that never answers is enough,
// the module treats a database that has not answered as simply not ready yet
globalThis.indexedDB ??= { open: () => ({}) }

const { cache, caches } = await import('@/modules/cache.js')
const { writable } = await import('simple-store-svelte')

/** A store entry that expired a minute ago. */
const staleEntry = (data) => ({ data, expiry: Date.now() - 60_000, cachedAt: Date.now() - 3_600_000 })
/** A store entry that is still fresh. */
const freshEntry = (data) => ({ data, expiry: Date.now() + 60_000, cachedAt: Date.now() })

/** A promise that resolves when told to, standing in for a request in flight. */
const pending = () => {
  let resolve
  const promise = new Promise((r) => { resolve = r })
  return { promise, resolve }
}

describe('which stores allow serving stale', () => {
  it('query metadata does, user-owned data never', () => {
    for (const store of [caches.QUERY_SEARCH, caches.QUERY_SEARCH_IDS, caches.QUERY_EPISODES, caches.QUERY_MAPPINGS, caches.QUERY_COMPOUND, caches.QUERY_RSS]) {
      expect(store.swr).toBe(true)
    }
    // when user lists or notifications are refetched, the fresh answer is the point
    for (const store of [caches.USER_LISTS, caches.QUERY_FOLLOWING, caches.QUERY_RECOMMENDATIONS, caches.NOTIFICATIONS, caches.QUERY_NOTIFICATIONS, caches.GENERAL, caches.HISTORY, caches.MEDIA_CACHE, caches.EXTENSIONS]) {
      expect(store.swr).toBeUndefined()
    }
  })
})

describe('cacheEntry with a request in flight', () => {
  it('serves the expired entry immediately and lands the fresh one behind it', async () => {
    cache.query_rss = writable({ feed: staleEntry('<stale/>') })
    const request = pending()

    const served = cache.cacheEntry(caches.QUERY_RSS, 'feed', {}, request.promise, Date.now() + 60_000)
    expect(await served).toBe('<stale/>')

    request.resolve('<fresh/>')
    await request.promise
    await Bun.sleep(0) // the revalidation's own then-chain
    expect(cache.query_rss.value.feed.data).toBe('<fresh/>')
    expect(cache.query_rss.value.feed.expiry).toBeGreaterThan(Date.now())
  })

  it('waits for the network when nothing is stored at all', async () => {
    cache.query_rss = writable({})
    const request = pending()
    const served = cache.cacheEntry(caches.QUERY_RSS, 'feed', {}, request.promise, Date.now() + 60_000)
    request.resolve('<fresh/>')
    expect(await served).toBe('<fresh/>')
  })

  it('honours an explicit cache bypass', async () => {
    cache.query_search_ids = writable({ '{"skipCache":true}': staleEntry({ data: {} }) })
    const request = pending()
    const served = cache.cacheEntry(caches.QUERY_SEARCH_IDS, '{"skipCache":true}', { skipCache: true }, request.promise, Date.now() + 60_000)
    const fresh = { data: {} }
    request.resolve(fresh)
    expect(await served).toEqual(fresh)
  })

  it('never trades an already-resolved value for a stale row', async () => {
    // a completed download being recorded is fresher than anything stored
    cache.query_rss = writable({ feed: staleEntry('<stale/>') })
    const served = cache.cacheEntry(caches.QUERY_RSS, 'feed', {}, '<fresh/>', Date.now() + 60_000)
    expect(await served).toBe('<fresh/>')
  })

  it('stores without the flag keep waiting for the network', async () => {
    cache.query_following = writable({ me: staleEntry({ data: {} }) })
    const request = pending()
    const served = cache.cacheEntry(caches.QUERY_FOLLOWING, 'me', {}, request.promise, Date.now() + 60_000)
    const fresh = { data: {} }
    request.resolve(fresh)
    expect(await served).toEqual(fresh)
  })

  it('a fresh entry is still answered from cachedEntry before any request starts', () => {
    cache.query_rss = writable({ feed: freshEntry('<current/>') })
    expect(cache.cachedEntry(caches.QUERY_RSS, 'feed', false)).resolves.toBe('<current/>')
  })
})
