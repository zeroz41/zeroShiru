// The shared account listing. Two callers want the same list — the badge refresh once a minute,
// and every resolve, checking whether the account already holds the release — and reading it per
// play put a full listing on the play path (4.6s on a 312 torrent Real-Debrid account). These
// tests pin the sharing, and the invalidation that is the price of it.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import DebridService, { DebridNotImplementedError } from '../../../common/modules/debrid/service.js'

/** A service whose listing is a counted, controllable read. */
class Listed extends DebridService {
  static id = 'listed'
  static title = 'Listed'
  reads = 0
  torrents = [{ id: 1, hash: 'a'.repeat(40) }]
  delay = 0
  fail = null
  async fetchListing () {
    this.reads++
    if (this.delay) await new Promise(resolve => setTimeout(resolve, this.delay))
    if (this.fail) throw this.fail
    return this.torrents
  }
}

test('a listing read within the TTL is handed to every caller instead of repeated', async () => {
  const service = new Listed('key')
  const first = await service.listing()
  const second = await service.listing()
  assert.equal(service.reads, 1, 'the second caller must not pay for another read')
  assert.equal(first, second, 'and gets the same list')
  service.destroy()
})

// the case that made this worth building: the modal opens and refreshes badges, then the user
// plays something, and the resolve wants the same list a second later
test('browsing and then playing costs one read, not two', async () => {
  const service = new Listed('key')
  await service.listing() // badge refresh
  await service.listing() // resolve looking for an existing torrent
  assert.equal(service.reads, 1)
  service.destroy()
})

test('callers racing for a cold listing share the one request', async () => {
  const service = new Listed('key')
  service.delay = 20
  const [a, b, c] = await Promise.all([service.listing(), service.listing(), service.listing()])
  assert.equal(service.reads, 1, 'a listing in flight must be joined, not duplicated')
  assert.equal(a, b)
  assert.equal(b, c)
  service.destroy()
})

test('the listing is read again once it is older than its TTL', async () => {
  class Brief extends Listed { static listingTTL = 5 }
  const service = new Brief('key')
  await service.listing()
  await new Promise(resolve => setTimeout(resolve, 15))
  await service.listing()
  assert.equal(service.reads, 2)
  service.destroy()
})

test('a caller that just changed the account can force a fresh read', async () => {
  const service = new Listed('key')
  await service.listing()
  await service.listing({ fresh: true })
  assert.equal(service.reads, 2, 'polling a change you just made must not be answered from memory')
  service.destroy()
})

test('a failed read is never remembered as the state of the account', async () => {
  const service = new Listed('key')
  service.fail = new Error('the account list dropped mid-response')
  await assert.rejects(() => service.listing())
  service.fail = null
  assert.deepEqual(await service.listing(), service.torrents, 'the next caller retries rather than inheriting the failure')
  assert.equal(service.reads, 2)
  service.destroy()
})

// staleness is the whole cost of sharing, so anything that changes the account has to say so
test('forgetting the listing makes the next caller read it again', async () => {
  const service = new Listed('key')
  await service.listing()
  service.forgetListing()
  await service.listing()
  assert.equal(service.reads, 2)
  service.destroy()
})

test('removing something from the account invalidates the listing automatically', async () => {
  const service = new Listed('key')
  globalThis.fetch = async () => ({ ok: true, status: 204, headers: { get: () => null }, json: async () => null })
  await service.listing()
  await service.release('https://example.test/torrents/delete/1')
  await service.listing()
  assert.equal(service.reads, 2, 'a delete must not leave the removed torrent in the remembered listing')
  service.destroy()
})

test('a service that has not implemented its listing says so by name', async () => {
  class Unfinished extends DebridService {
    static id = 'unfinished'
    static title = 'Unfinished'
  }
  const service = new Unfinished('key')
  await assert.rejects(() => service.listing(), DebridNotImplementedError)
  service.destroy()
})
