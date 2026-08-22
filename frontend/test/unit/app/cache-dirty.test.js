// The dirty-key persistence pass in cache.js: a cache write used to hand the
// persistence subscriber no delta, so it compared every entry of every store on every
// notification — ten thousand deep-equals and a clone per media on each of the
// fifteen-odd writes a home load makes, on the main thread. Mutations now mark what
// they touched and syncStoreSnapshot compares exactly that; the full pass survives
// only as the page-hide audit. These tests pin the pass itself: what gets queued,
// what the shadow remembers, and how media entries split their user fields out.
import { describe, it, expect } from 'bun:test'

globalThis.indexedDB ??= { open: () => ({}) }
const { syncStoreSnapshot, fromCache } = await import('@/modules/cache.js')

describe('syncStoreSnapshot', () => {
  it('compares only the candidates, and remembers what it persisted', () => {
    const enqueued = []
    const shadow = { a: 1, b: 2 }
    const value = { a: 10, b: 20, c: 30 }
    syncStoreSnapshot({ value, shadow, candidates: ['a'], enqueue: (key, val) => enqueued.push([key, val]) })
    expect(enqueued).toEqual([['a', 10]], 'b changed too, but nothing marked it')
    expect(shadow.a).toBe(10)
    expect(shadow.b).toBe(2, 'the shadow only advances for what was compared')
  })

  it('an unchanged candidate costs a comparison and no write', () => {
    const enqueued = []
    const shadow = { a: { deep: [1, 2] } }
    syncStoreSnapshot({ value: { a: { deep: [1, 2] } }, shadow, candidates: ['a'], enqueue: (key) => enqueued.push(key) })
    expect(enqueued).toEqual([])
  })

  it('the full pass catches everything, which is what the page-hide audit runs', () => {
    const enqueued = []
    syncStoreSnapshot({ value: { a: 1, b: 2 }, shadow: {}, candidates: true, enqueue: (key) => enqueued.push(key) })
    expect(enqueued.sort()).toEqual(['a', 'b'])
  })

  it('reports entries that vanished, whatever was marked', () => {
    const shadow = { gone: 1, kept: 2 }
    const removed = syncStoreSnapshot({ value: { kept: 2 }, shadow, candidates: [], enqueue: () => {} })
    expect(removed).toEqual(['gone'])
    expect(shadow.gone).toBeUndefined()
  })

  it('splits user fields out of media entries and reports when they are gone', () => {
    const enqueued = []
    const fields = []
    const media = { id: 7, title: 'Show', mediaListEntry: { status: 'CURRENT' } }
    syncStoreSnapshot({
      value: { 7: media },
      shadow: {},
      candidates: ['7'],
      isMedia: true,
      enqueue: (key, val) => enqueued.push(val),
      onUserFields: (key, userFields) => fields.push(userFields)
    })
    expect(enqueued[0].mediaListEntry).toBeUndefined()
    expect(enqueued[0].title).toBe('Show')
    expect(fields[0]).toEqual({ mediaListEntry: { status: 'CURRENT' } })

    fields.length = 0
    syncStoreSnapshot({
      value: { 7: { id: 7, title: 'Show' } },
      shadow: {},
      candidates: ['7'],
      isMedia: true,
      enqueue: () => {},
      onUserFields: (key, userFields) => fields.push(userFields)
    })
    expect(fields[0]).toBeNull('an entry whose user fields disappeared must say so, or user_lists keeps a ghost')
  })
})

describe('fromCache memoization', () => {
  it('a repeated comparison against the same pair is remembered, and stays correct', () => {
    const current = { id: 7, title: { english: 'Show' } }
    const updated = { id: 7, title: { english: 'Show' }, extra: true }
    const cacheValue = { 7: updated }
    // the memo must not change the verdict across the repeated calls every card makes
    for (let i = 0; i < 3; i++) expect(fromCache(cacheValue, current)).toBe(updated)
    const same = { id: 7, title: { english: 'Show' } }
    for (let i = 0; i < 3; i++) expect(fromCache({ 7: same }, current)).toBe(current)
  })
})
