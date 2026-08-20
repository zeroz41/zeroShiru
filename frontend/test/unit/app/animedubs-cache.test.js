// The dub list is ~60KB of MyAnimeList ids that changes a few times a week, and
// the entry getMALDubs writes was never read back online — every boot fetched it
// again with a cache-busting timestamp. The rule now: a fresh cached copy answers
// outright, and the fetch that does happen is revalidatable by the HTTP cache.
import { describe, it, expect } from 'bun:test'

globalThis.indexedDB ??= { open: () => ({}) }

const fetchCalls = []
globalThis.fetch = async (url) => {
  fetchCalls.push(String(url))
  return { ok: true, json: async () => ({ dubbed: [999], incomplete: [] }) }
}

const { cache, caches } = await import('@/modules/cache.js')
const { writable } = await import('simple-store-svelte')

const stored = { dubbed: [123], incomplete: [456] }
cache.query_rss = writable({
  MALDubs: { data: stored, expiry: Date.now() + 60_000, cachedAt: Date.now() }
})

// importing constructs the singleton, which loads the dub list right away
const { malDubs } = await import('@/modules/anime/animedubs.js')

describe('the dub list on boot', () => {
  it('is answered by a fresh cached copy without touching the network', async () => {
    expect(await malDubs.dubLists.value).toEqual(stored)
    expect(fetchCalls).toHaveLength(0)
  })

  it('is fetched once expired, without a cache-busting timestamp', async () => {
    cache.query_rss.value.MALDubs.expiry = Date.now() - 1
    expect(await malDubs.getMALDubs()).toEqual({ dubbed: [999], incomplete: [] })
    expect(fetchCalls).toHaveLength(1)
    expect(fetchCalls[0]).toContain('dubInfo.json')
    // a unique URL per boot makes every HTTP cache between us and the file useless
    expect(fetchCalls[0]).not.toContain('timestamp=')
    expect(fetchCalls[0]).not.toContain('?')
  })
})
