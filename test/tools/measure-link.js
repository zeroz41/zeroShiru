// Measures what a debrid availability sweep costs on the connection you are actually on.
//
// This is the tool the slow-link work was done with: it times every HTTP round trip, shows how
// long each release takes to answer and why, and prints the latency the client's own time limits
// are being scaled by. Run it when badges feel slow or incomplete, before changing anything.
//
//   REAL_DEBRID_API_KEY=xxx node --import ./register.js tools/measure-link.js [hash...]
//   TORBOX_API_KEY=xxx     node --import ./register.js tools/measure-link.js [hash...]
//
// Any extra arguments are info hashes to ask about, most relevant first, the same way the
// results list feeds them in. With none, it uses a torrent almost every service holds.
import RealDebrid from '../../common/modules/debrid/realdebrid.js'
import TorBox from '../../common/modules/debrid/torbox.js'

const services = [
  { Service: RealDebrid, key: process.env.REAL_DEBRID_API_KEY },
  { Service: TorBox, key: process.env.TORBOX_API_KEY }
].filter(entry => entry.key)

if (!services.length) {
  console.error('Set REAL_DEBRID_API_KEY and/or TORBOX_API_KEY.')
  process.exit(1)
}

// the poll loops inside the clients unref their timers, so nothing here keeps the process alive
const keepalive = setInterval(() => {}, 1_000)

// the canonical webtorrent test torrent, near certain to be cached on any debrid service
const BBB = '08ada5a7a6183aae1e09d831df6748d566095a10'
const hashes = process.argv.slice(2).length ? process.argv.slice(2) : [BBB]

for (const { Service, key } of services) {
  const service = new Service(key)
  const started = Date.now()
  const stamp = () => `${String(Date.now() - started).padStart(6)}ms`
  const timings = []

  // wrap the rate limited request so every round trip is timed as the client sees it
  const inner = service.request
  service.request = async (url, opts) => {
    const at = Date.now()
    try {
      return await inner(url, opts)
    } finally {
      const took = Date.now() - at
      timings.push(took)
      console.log(`${stamp()}  ${String(took).padStart(5)}ms  ${(opts?.method || 'GET').padEnd(6)} ${url.replace(/^https:\/\/[^/]+/, '')}`)
    }
  }

  console.log(`\n=== ${Service.title} (${Service.availabilityCheck} check, looks at up to ${Service.maxAsk} results) ===\n`)

  console.log('--- account listing, the free badge source ---')
  const listAt = Date.now()
  const known = await service.listAvailability()
  console.log(`${stamp()}  ${known.size} releases badged from the account in ${Date.now() - listAt}ms\n`)

  console.log('--- availability check ---')
  const sweepAt = Date.now()
  const answers = await service.checkAvailability(hashes, {
    onAnswer: (hash, state) => console.log(`${stamp()}  ANSWER ${hash.slice(0, 12)} -> ${state}`)
  })
  const sweep = Date.now() - sweepAt

  const sorted = [...timings].sort((a, b) => a - b)
  console.log(`\n${answers.size}/${hashes.length} answered in ${(sweep / 1_000).toFixed(1)}s over ${timings.length} requests`)
  console.log(`round trip: median ${sorted[sorted.length >> 1]}ms, worst ${sorted[sorted.length - 1]}ms`)
  // what the client itself thinks of the link, and what it does about it
  console.log(`client estimate: ${service.latency}ms, so time limits run at ${(service.budget('ready') / Service.timeouts.ready).toFixed(1)}x their defaults`)
  if (answers.size < hashes.length) console.log(`${hashes.length - answers.size} left unanswered — the app retries these on a backing off timer rather than badging them`)
  service.destroy()
}

clearInterval(keepalive)
