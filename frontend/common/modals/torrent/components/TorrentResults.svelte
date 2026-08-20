<script context='module'>
  import { settings } from '@/modules/settings.js'
  import { debounce, matchPhrase } from '@/modules/util.js'
  import { sanitiseTerms } from '@/modals/torrent/components/TorrentCard.svelte'
  import { add } from '@/modules/torrent.js'
  import { nowPlaying as currentMedia } from '@/components/MediaHandler.svelte'
  import { animeSchedule } from '@/modules/anime/animeschedule.js'
  import { cache, caches } from '@/modules/cache.js'
  import { status } from '@/modules/networking.js'
  import { anitomyscript, getMediaMaxEp, getKitsuMappings, getEpisodeMetadataForMedia } from '@/modules/anime/anime.js'
  import { loadedTorrent, completedTorrents, seedingTorrents, stagingTorrents } from '@/modules/torrent.js'
  import { dedupe, getTorrentResults, updatePeerCounts } from '@/modules/extensions/handler.js'
  import { releaseHoldsEpisode } from '@/modules/playback/coverage.js'
  import { debridEnabled, debridAvailability, debridTransport, debridChecking, debridReleaseNames, refreshDebridAvailability, checkDebridAvailability, cancelDebridAvailability } from '@/modules/debrid/debrid.js'
  import { Availability, AVAILABILITY_ORDER, availabilityOf, describeAvailability, preferCached } from '@/modules/debrid/availability.js'
  import { get } from 'svelte/store'
  import { listResult } from '@/modules/debrid/route.js'
  import { getId, getHash } from '@/modules/anime/animehash.js'
  import AnimeResolver from '@/modules/anime/animeresolver.js'
  import { anilistClient } from '@/modules/providers/anilist/anilist.js'
  import { click } from '@/modules/lib/click.js'
  import { toast } from 'svelte-sonner'
  import NestedDropdown from '@/components/overlays/NestedDropdown.svelte'
  import { X, Search, EllipsisVertical, Timer, Clapperboard, MonitorCog, ArrowDownWideNarrow, Paintbrush, ListMusic, ChevronUp, ChevronDown, Radio, RefreshCw, Cloud } from 'lucide-svelte'
  import Debug from 'debug'
  const debug = Debug('ui:torrents')

  /** @typedef {import('@/modules/providers/anilist/al.d.ts').Media} Media */
  /** @typedef {import('anitomyscript').AnitomyResult} AnitomyResult */
  /** @typedef {import('../../../../extensions').TorrentResult} Result */

  /** @param {Media} media */
  function isMovie (media) {
    if (!media) return false
    if (media.format === 'MOVIE') return true
    if ([...Object.values(media.title), ...media.synonyms].some(title => title?.toLowerCase().includes('movie') && !title?.toLowerCase().includes('short'))) return true // TODO: revisit this, it causes false positives since the term "movie" is used randomly on shorts that are clearly not movie length.
    // if (!getParentForSpecial(media)) return true // TODO: this is good for checking movies, but false positives with normal TV shows
    return media.duration > 80 && media.episodes === 1
  }

  /**
   * @param {Object} search
   * @param {AnitomyResult} result
   * @param {string} audioLang
   * @param {boolean} exactMatch
   */
  async function getRequestedAudio(search, result, audioLang, exactMatch = true) {
    const terms = [...new Map((await sanitiseTerms(search, result))?.map(term => [term.term.text, term.term])).values()]
    const checkTerm = (term, keyword) => (Array.isArray(term.text) ? term.text : [term.text]).some(text => text.toLowerCase().includes(keyword.toLowerCase()))
    const exactAudio = terms.some(term => checkTerm(term, audioLang))
    const dualAudio = terms.some(term => checkTerm(term, 'dual'))
    return exactAudio || (exactMatch ? exactAudio : dualAudio)
  }

  /**
   * @param {Object} search
   * @param {Result[]} results
   * @param {string} audioLang
   * @param {string[]} torrentProvider
   */
  async function getBest(search, results, audioLang, torrentProvider = []) {
    if (!results || !results.length) return null
    const candidates = []
    if (audioLang !== 'jpn') {
      const checks = await Promise.all(
        results.map(async result => ({
          result,
          exactBest: (await getRequestedAudio(search, result.parseObject, audioLang)) && result.seeders > 9,
          exactAlt: (await getRequestedAudio(search, result.parseObject, audioLang, false)) && result.seeders > 9,
          dualBest: (await getRequestedAudio(search, result.parseObject, audioLang)) && result.seeders > 1,
          dualAlt: (await getRequestedAudio(search, result.parseObject, audioLang, false)) && result.seeders > 1
        })))
      candidates.push(...checks.filter(check => check.exactBest).map(check => check.result), ...checks.filter(check => check.exactAlt).map(check => check.result), ...checks.filter(check => check.dualBest).map(check => check.result), ...checks.filter(check => check.dualAlt).map(check => check.result))
    }
    candidates.push(...results.filter(result => (result.type === 'best' || result.type === 'alt') && result.seeders > 9))
    const uniqueCandidates = Array.from(new Set(candidates))
    // a release the debrid service already holds beats any seeder count: picking an
    // uncached one is choosing a resolve failure and a fall back to the torrent lane.
    // module context, so the stores are read explicitly rather than via $
    const considered = uniqueCandidates.length ? uniqueCandidates : results
    const toConsider = get(debridEnabled) ? preferCached(considered, debridAvailability.value) : considered
    if (torrentProvider?.length) {
      const filteredByProvider = toConsider.filter(result => result.parseObject?.release_group && torrentProvider.some(provider => result.parseObject.release_group.toLowerCase().includes(provider.toLowerCase())))
      if (filteredByProvider.length) return filteredByProvider[0]
    }
    return toConsider[0] || results[0]
  }

  function filterResults(results, searchText) {
    if (!searchText?.length) return results
    return results.filter(({ title }) => matchPhrase(searchText, title, 0.4, false, true)) || []
  }

  /**
   * @param {Result[]} results
   * @param {string} sort
   * @param {boolean} batch
   */
  function sortResults(results, sort, batch) {
    if (!results) return []
    const deduped = Array.from(dedupe(results)).map(result => {
      if (!(result.parseObject?.release_group && result.parseObject.release_group.length < 20)) result.parseObject = { ...result.parseObject, release_group: 'No Group' }
      return result
    })
    return deduped.sort((a, b) => {
      switch (sort) {
        case 'smallest': return a.size - b.size
        case 'best': return ((b.type === 'best') - (a.type === 'best') || (b.type === 'alt') - (a.type === 'alt')) || b.seeders - a.seeders
        case 'batch': {
          if (!batch) return b.seeders - a.seeders
          return ((b.type === 'batch') - (a.type === 'batch')) || b.seeders - a.seeders
        }
        case 'new': return new Date(b.date) - new Date(a.date)
        case 'old': return new Date(a.date) - new Date(b.date)
        case 'seeders':
        default: return b.seeders - a.seeders
      }
    })
  }

  const sameOrder = (a, b) => a.length === b.length && a.every((entry, index) => entry === b[index])

  /**
   * Splits sorted results into what is listed and what is hidden, and tallies what the debrid
   * service said about each. Kept apart from the sorting above so an answer landing only redoes
   * these passes, not the dedupe and sort. The previous split lives in the closure rather than a
   * component variable to stay out of the reactive graph.
   * @returns {(sorted: Result[], availability?: Map<string, string>, filters?: { cachedOnly?: boolean, only?: boolean }) => any}
   */
  function createListResults() {
    let previous = null
    return function listResults(sorted, availability, filters) {
      const results = []
      const hiddenResults = []
      const counts = Object.fromEntries(AVAILABILITY_ORDER.map(state => [state, 0]))
      for (const entry of sorted) {
        const state = availability ? availabilityOf(availability, entry.hash) : Availability.UNKNOWN
        counts[state]++
        // narrows what the rest of the modal sees, so the best pick and autoplay follow it too
        if (listResult(entry, state, filters)) results.push(entry)
        else hiddenResults.push(entry)
      }
      // most answers only move the counts, since a seeded release was listed either way. Handing
      // back the same arrays keeps the best-release pick from being redone, which reparses every
      // result and is what made answers landing feel like a freeze
      if (previous && sameOrder(previous.results, results) && sameOrder(previous.hiddenResults, hiddenResults)) {
        return { ...previous, counts }
      }
      return (previous = { sorted, counts, results, hiddenResults })
    }
  }

  const languages = [
    { value: 'jpn', label: 'Japanese' },
    { value: 'eng', label: 'English' },
    { value: 'chi', label: 'Chinese' },
    { value: 'por', label: 'Portuguese' },
    { value: 'spa', label: 'Spanish' },
    { value: 'ger', label: 'German' },
    { value: 'pol', label: 'Polish' },
    { value: 'cze', label: 'Czech' },
    { value: 'dan', label: 'Danish' },
    { value: 'gre', label: 'Greek' },
    { value: 'fin', label: 'Finnish' },
    { value: 'fre', label: 'French' },
    { value: 'hun', label: 'Hungarian' },
    { value: 'ita', label: 'Italian' },
    { value: 'kor', label: 'Korean' },
    { value: 'dut', label: 'Dutch' },
    { value: 'nor', label: 'Norwegian' },
    { value: 'rum', label: 'Romanian' },
    { value: 'rus', label: 'Russian' },
    { value: 'slo', label: 'Slovak' },
    { value: 'swe', label: 'Swedish' },
    { value: 'ara', label: 'Arabic' },
    { value: 'idn', label: 'Indonesian' }
  ]

  /**
   * Clean error messages by removing extension path prefixes and getting the correct error line(s)
   * @param {string} errorMessage The error message to clean
   * @return {string} The clean error message
   */
  function cleanErrorMessage(errorMessage) {
    if (!errorMessage) return 'Unknown error occurred'
    let cleaned = errorMessage.replace(/^Source\s+[a-z]+(?::\/\/|:)\S*\s+/i, '')
    const failedMatch = cleaned.match(/failed to load results:\s*(.+)/i)
    if (failedMatch) cleaned = failedMatch[1]
    return cleaned.replace(/\\n/g, ' ').trim() || 'Unknown error occurred'
  }
</script>

<script>
  import TorrentCard from '@/modals/torrent/components/TorrentCard.svelte'
  import TorrentCardSk from '@/components/skeletons/TorrentCardSk.svelte'
  import SmartImage from '@/components/visual/SmartImage.svelte'
  import ErrorCard from '@/components/cards/ErrorCard.svelte'
  import { onDestroy } from 'svelte'
  import { writable } from 'simple-store-svelte'

  /** @type {{ media: Media, episode?: number }} */
  export let search
  export let close

  const listResults = createListResults()
  let container
  let containerEl
  let countdown = 5
  let timeoutHandle
  const maxEpisode = 10_000
  const updateEpisode = debounce((value) => { if (search.episode !== value) search.episode = value }, 500)
  $: episodeSearch = search?.episode

  /**
   * @param {ReturnType<typeof getBest>} promise
   * @param {boolean} ready
   */
  async function autoPlay (promise, ready) {
    const best = await promise
    if (!search || !best || !ready) return
    if ($settings.rssAutoplay) {
      clearTimeout(timeoutHandle)
      const decrement = () => {
        countdown--
        if (countdown === 0) {
          play(best)
        } else {
          timeoutHandle = setTimeout(decrement, 1000)
        }
      }
      timeoutHandle = setTimeout(decrement, 1000)
    }
  }

  function dubFinished() {
    const airingMedia = animeSchedule.dubAiring.value?.find(entry => entry.media?.media?.id === search.media.id)
    return !airingMedia || (airingMedia.episodeNumber === search.media.episodes && (new Date().getTime() >= new Date(airingMedia.episodeDate).getTime())) || ((search.media.mediaListEntry?.progress ?? 0) > airingMedia.episodeNumber)
  }

  const movie = isMovie(search.media)
  let batch = search.media.status === 'FINISHED' && (!settings.value.preferDubs || dubFinished()) && (!movie || getMediaMaxEp(search.media) > 1)

  const results = writable({})
  function addResults(newItems, source) {
    if (!newItems?.length) return ''
    results.update(r => ({ ...r, torrents: [...(r?.torrents ?? []), ...newItems.map(item => ({ ...item, source }))] }))
    return ''
  }

  $: errorCardOnly = search && false
  function hideErrors() {
    errorCardOnly = true
    return ''
  }

  async function addCachedHashes(cachedHashes) {
    if (!cachedHashes?.length) return
    const cachedTorrents = []
    const torrents = [...completedTorrents.value, ...seedingTorrents.value, ...stagingTorrents.value, loadedTorrent.value].filter(Boolean)
    for (const cached of cachedHashes) {
      const torrent = torrents.find(torrent => torrent.infoHash === cached.hash)
      if (!torrent) continue
      const title = AnimeResolver.cleanFileName(torrent.name)
      let searchEpisode = search?.episode
      let isLocked = cached.locked ?? (cached.files?.length === 1 && (cached.files[0].locked || cached.files[0].parseObject?.locked)) ?? false
      if (!isLocked && Array.isArray(cached.files) && searchEpisode != null) {
        const normalizedEpisode = Number.isFinite(Number(searchEpisode)) ? Number(searchEpisode) : searchEpisode
        const matchingFile = cached.files.find(file => file.episode === normalizedEpisode)
        if (matchingFile) isLocked = matchingFile.locked ?? false
      }
      const parseObject = (await anitomyscript(title))?.[0]
      // these bypass getTorrentResults entirely, so they need the same check: a pack already on
      // disk is no more able to serve an episode it does not contain than one being searched for
      if (!releaseHoldsEpisode(parseObject, { episode: search?.episode, episodeCount: getMediaMaxEp(search?.media) })) {
        debug(`Hiding locally held ${title}, its title says it does not hold episode ${search?.episode}`)
        continue
      }
      cachedTorrents.push({
        title,
        link: torrent.magnetURI,
        seeders: torrent.totalSeeders ?? 0,
        leechers: torrent.totalLeechers ?? 0,
        hash: torrent.infoHash,
        size: torrent.size,
        date: torrent.date,
        accuracy: isLocked ? 'high' : 'medium',
        parseObject,
        source: { managed: true, name: `Local (${torrent.staging ? 'Staging' : torrent.seeding ? 'Seeding' : torrent.current ? 'Now Playing' : 'Completed'})` }
      })
    }
    if (cachedTorrents.length) results.update(result => ({ ...result, torrents: [...(result?.torrents ?? []), ...cachedTorrents] }))
  }

  async function queryExtensions(request, resolution) {
    scrollTop()
    if ($debridEnabled) refreshDebridAvailability()
    $results = {}
    const cachedHashes = []
    for (const resolvedHash of getHash(search?.media?.id, { episode: search?.episode, client: true, batchGuess: true }, false, true, true) ?? []) {
      if (resolvedHash) {
        const cachedFile = getId(resolvedHash, { fileHash: resolvedHash }, true)
        if (cachedFile) cachedHashes.push(cachedFile)
        else {
          const cachedTorrent = getId(resolvedHash, {}, true)
          if (cachedTorrent) cachedHashes.push(cachedTorrent)
        }
      }
    }
    await addCachedHashes(cachedHashes)
    debug(`Querying extensions for torrent sources for ${search?.media?.id}`)
    let promises
    try {
      promises = await getTorrentResults({ ...request, batch, movie, resolution })
    } catch (error) {
      if (search != null && search.media?.id === request?.media?.id && search.episode === request?.episode) {
        errors = Promise.resolve({ errors: [error] })
        results.update(r => ({...r, resolved: true}))
      }
    }
    if (search == null || search.media?.id !== request?.media?.id) return null
    debug(`Query promises from extensions have been accepted for ${search?.media?.id}`)
    return promises
  }

  async function getErrors(request, promises) {
    const queries = await promises
    if (!queries) return null
    const uniqueErrors = new Set()
    await (async () => {
      (await Promise.all(Array.from(queries, ([_, extension]) => extension.promise))).forEach((result) => {
        if (result.errors && result.errors.length > 0) result.errors.forEach((error) => uniqueErrors.add(error.message))
      })
    })()
    if (search == null || search.media?.id !== request?.media?.id || search.episode !== request?.episode) return null
    results.update(r => ({ ...r, resolved: true }))
    debug(`All query promises have successfully been resolved for ${search?.media?.id}:E${search?.episode}`, JSON.stringify(Array.from(uniqueErrors)))
    const errorsArray = Array.from(uniqueErrors)
    if (errorsArray.some(msg => msg?.includes('sources configured') || msg?.includes('Sources are inactive'))) return { errors: errorsArray.map((message) => ({ message })), errorCardOnly: true }
    if ($status !== 'offline' && JSON.stringify(Array.from(uniqueErrors)).match(/found no results/i) && (search?.media?.status !== 'FINISHED' || !search?.media?.episodes) && (getMediaMaxEp(search?.media, true) < search?.episode)) {
      return { errors: [ { message: `${anilistClient.title(search.media)} ${search.media?.format !== 'MOVIE' || (getMediaMaxEp(search?.media, false) > 1) ? `Episode ${search.media.nextAiringEpisode?.episode || search.episode}` : ``} hasn't released yet! ${search?.media?.nextAiringEpisode?.timeUntilAiring ? `\n${search.media?.format !== 'MOVIE' || (getMediaMaxEp(search?.media, false) > 1) ? `This episode` : `This movie`} will be released on ${new Date(Date.now() + search.media.nextAiringEpisode?.timeUntilAiring * 1000).toDateString()}` : ''}` }], errorCardOnly: true }
    }
    return { errors: Array.from(uniqueErrors).map((message) => ({ message })) }
  }

  let scraping = false
  async function handleScrape() {
    scrollTop()
    if (!$results?.resolved || !$results?.torrents?.length || scraping) return
    toast.promise(
      (async () => {
        try {
          scraping = true
          const beforeScrape = $results.torrents.map(torrent => ({ hash: torrent.hash, seeders: torrent.seeders, leechers: torrent.leechers}))
          const updatedResults = await updatePeerCounts($results.torrents)
          results.update(result => ({ ...result, torrents: updatedResults }))
          const changedCount = updatedResults.filter((torrent, index) => {
            const before = beforeScrape[index]
            return before && (torrent.seeders !== before.seeders || torrent.leechers !== before.leechers)
          }).length
          return { total: updatedResults.length, changed: changedCount }
        } finally {
          scraping = false
        }
      })(), {
        loading: `Scraping peer data for ${$results.torrents.length} torrent${$results.torrents.length === 1 ? '' : 's'}...`,
        success: (data) => {
          if (data.changed === 0) return `Peer counts are up to date! All ${data.total} torrent${data.total === 1 ? '' : 's'} checked, no changes detected.`
          if (data.changed === data.total) return `Successfully refreshed peer counts for ${data.total} torrent${data.total === 1 ? '' : 's'}!`
          return `Successfully refresh peer counts and found differences for ${data.changed} of ${data.total} torrent${data.total === 1 ? '' : 's'}`
        },
        error: (error) => `Failed to scrape peer data: ${error?.message || 'Please try again later.'}`
      }
    )
  }

  $: resolution = $settings.rssQuality
  $: queries = queryExtensions({...search}, resolution)
  $: errors = getErrors({...search}, queries)
  $: cachedOnly = $debridEnabled && $settings.debridCachedOnly
  $: debridFilters = { cachedOnly, only: $debridEnabled && Boolean($debridTransport?.only) }
  /**
   * A search source is free to invent a title, and one of them does: SeaDex replaces a multi
   * file release's name with `[Group] Show Dual Audio`, which says nothing about which episodes
   * are inside, so a two episode fix release looked identical to a full series batch and was
   * offered for every episode. Anything that knows the release's real name — the debrid service,
   * which names what it answers about, or the torrent client for one it already holds — gives a
   * name worth judging in place of the invented one.
   * @type {Record<string, any>} Parsed real names, keyed by info hash.
   */
  let realParses = {}

  /** The real names the torrent client knows, for releases it holds. */
  function localNames() {
    const known = new Map()
    for (const torrent of [...completedTorrents.value, ...seedingTorrents.value, ...stagingTorrents.value, loadedTorrent.value]) {
      if (torrent?.infoHash && torrent?.name) known.set(torrent.infoHash, torrent.name)
    }
    return known
  }

  async function judgeByRealName(torrents, names) {
    let learned = false
    const local = localNames()
    for (const result of torrents ?? []) {
      const hash = result?.hash
      if (!hash || realParses[hash]) continue
      const real = names?.get(hash) || local.get(hash)
      if (!real || real === result.title) continue
      realParses[hash] = (await anitomyscript(real))?.[0] ?? null
      const holds = releaseHoldsEpisode(realParses[hash], { episode: search?.episode, episodeCount: getMediaMaxEp(search?.media) })
      debug(`${holds ? 'Keeping' : 'Hiding'} "${result.title}" for episode ${search?.episode}: its real name is "${real}"`)
      learned = true
    }
    if (learned) realParses = { ...realParses }
  }

  $: judgeByRealName($results?.torrents, $debridReleaseNames)
  // hidden reactively rather than at search time: a real name can arrive after the list does
  $: hiddenByEpisode = new Set(Object.entries(realParses)
    .filter(([, parsed]) => parsed && !releaseHoldsEpisode(parsed, { episode: search?.episode, episodeCount: getMediaMaxEp(search?.media) }))
    .map(([hash]) => hash))
  $: sortedResults = sortResults(($results?.torrents ?? []).filter(result => !hiddenByEpisode.has(result.hash)), $settings.torrentSort, batch)
  // ask about the results from the top of the list down, which is where the releases worth
  // playing are. How far it reaches is the service's call: one request for a service with a
  // cache endpoint, a handful of probes for one without.
  // asked as sources answer rather than once every one of them has: waiting for the whole
  // set means one slow source leaves the list with no badges at all. Debounced because
  // sources land in a burst and every arrival rewrites the list — without it a five source
  // search asks the service six overlapping questions inside a second, which is how an
  // account gets rate limited
  const askAboutResults = debounce(hashes => checkDebridAvailability(hashes), 250)
  $: if ($debridEnabled && ($results?.resolved || sortedResults.length)) askAboutResults(sortedResults.map(result => result.hash))
  $: queryResults = listResults(sortedResults, $debridEnabled ? $debridAvailability : undefined, debridFilters)
  // every state and its count, for the tooltip on the cached filter
  $: availabilitySummary = AVAILABILITY_ORDER.map(state => `${queryResults?.counts?.[state] ?? 0} ${describeAvailability(state, $debridTransport?.title).label}`).join(' · ')
  $: lookup = queryResults?.results
  $: (episodeSearch || resolution || $settings.torrentSort || $settings.audioLanguage) && scrollTop()

  $: best = null
  let current = 0
  let bestPromiseId = current
  $: {
    bestPromiseId = ++current
    resolveBest(search, lookup, $settings.audioLanguage, $settings.torrentProvider)
  }
  async function resolveBest(search, lookup, audioLanguage, torrentProvider = []) {
    const result = await getBest(search, lookup, audioLanguage, torrentProvider)
    if (bestPromiseId === current) best = result
  }

  $: lookupHidden = queryResults?.hiddenResults
  $: viewHidden = false

  $: if (!$settings.rssAutoplay) clearTimeout(timeoutHandle)
  $: autoPlay(best, $results?.resolved)

  const lastMagnet = cache.getEntry(caches.HISTORY, 'lastMagnet')?.[`${search?.media?.id}`]?.[`${search?.episode}`] || cache.getEntry(caches.HISTORY, 'lastMagnet')?.[`${search?.media?.id}`]?.batch
  let searchText = ''

  /** @param {import('../../../../extensions').TorrentResult} result */
  function play (result) {
    $currentMedia = search
    $currentMedia.accuracy = result.accuracy
    const existingMagnets = cache.getEntry(caches.HISTORY, 'lastMagnet') || {}
    cache.setEntry(caches.HISTORY, 'lastMagnet', { ...existingMagnets, [search?.media?.id]: !result.parseObject?.episode_number || Array.isArray(result.parseObject.episode_number) ? { [`batch`]: result } : { ...(existingMagnets[search?.media?.id] || {}), [`${search.episode}`]: result } })
    add(result.link, { media: search?.media, episode: search?.episode }, result.hash)
    close()
  }

  function episodeInput ({ target }) {
    const episode = Math.floor(Number(target.value))
    const episodeValue = episode > maxEpisode ? maxEpisode : episode
    if (episodeSearch === episodeValue) {
      target.value = episodeValue
      episodeSearch = episodeValue
      updateEpisode(episodeValue)
    } else if (episode || episode === 0) {
      target.value = episodeValue
      episodeSearch = episodeValue
      updateEpisode(episodeValue)
    }
  }

  function autoPlayToggle() {
    $settings.rssAutoplay = !$settings.rssAutoplay
    if ($settings.rssAutoplay) countdown = 5
  }

  function scrollTop() {
    container?.scrollTo({ top: 0, behavior: 'smooth' })
  }

  onDestroy(() => {
    clearTimeout(timeoutHandle)
    cancelDebridAvailability() // nobody is looking at these results any more
    viewHidden = false
    $results = {}
    search = null
    best = null
    current = 0
    bestPromiseId = 0
    scraping = false
    errorCardOnly = false
  })
</script>
<div class='h-full overflow-hidden d-flex flex-column' bind:this={containerEl}>
  <div class='controls w-full bg-very-dark position-sticky top-0 z-10 pt-md-wh-20 pb-5 px-30 mb-10'>
    <div class='d-flex'>
      <h3 class='mb-0 font-weight-bold text-white title mr-5 font-scale-40'>{anilistClient.title(search?.media)}</h3>
      <button type='button' class='btn btn-square bg-dark-very-light mt-20 ml-auto d-flex align-items-center justify-content-center rounded-2 flex-shrink-0' use:click={close}><X size='1.7rem' strokeWidth='3'/></button>
      <div class='position-absolute top-0 left-0 w-full h-full z--1'>
        <div class='position-absolute w-full h-full overflow-hidden' >
          <SmartImage class='img-cover w-full h-full' images={[
            search.media.bannerImage,
            ...(search.media.trailer?.id ? [
              `https://i.ytimg.com/vi/${search.media.trailer.id}/maxresdefault.jpg`,
              `https://i.ytimg.com/vi/${search.media.trailer.id}/hqdefault.jpg`] : []),
            () => getKitsuMappings(search.media.id).then(metadata =>
              [metadata?.included?.[0]?.attributes?.coverImage?.original,
              metadata?.included?.[0]?.attributes?.coverImage?.large,
              metadata?.included?.[0]?.attributes?.coverImage?.small,
              metadata?.included?.[0]?.attributes?.coverImage?.tiny]),
            () => getEpisodeMetadataForMedia(search.media).then(metadata => metadata?.[1]?.image),
            search.media.coverImage?.extraLarge]}
          />
        </div>
        <div class='position-absolute top-0 left-0 w-full h-full' style='background: var(--torrent-banner-gradient)' />
      </div>
    </div>
    <div class='input-group mt-20 h-40 long-input z-11'>
      <Search size='2.6rem' strokeWidth='2.5' class='position-absolute z-10 text-dark-light h-full pl-10 pointer-events-none' />
      <input
        type='search'
        class='form-control bg-dark-very-light pl-40 pr-30 rounded-3 h-40 text-truncate'
        autocomplete='off'
        spellcheck='false'
        data-option='search'
        placeholder='Filter torrents by text, or manually specify one by pasting a magnet link or torrent file' bind:value={searchText} />
      <div class='position-absolute right-0 h-full d-flex'>
        <NestedDropdown direction='left' panelHeightPadding={6.5} title='More Filters' alignStart={true} {containerEl} items={[
            {
              icon: Paintbrush,
              label: 'Auto-Scrape Results',
              value: $settings.torrentAutoScrape ? 'On' : 'Off',
              onSelect: () => $settings.torrentAutoScrape = !$settings.torrentAutoScrape
            },
            {
              icon: ListMusic,
              label: 'Preferred Audio',
              value: languages.find(language => language.value === $settings.audioLanguage)?.label,
              children: languages.map(language => ({
                label: language.label,
                value: language.value === $settings.audioLanguage ? '✓' : undefined,
                valueCSS: 'text-primary font-size-18 font-weight-very-bold',
                onSelect: () => $settings.audioLanguage = language.value
              })),
            }
          ]}>
          <button type='button' class='options h-full bg-transparent shadow-none border-0 pointer p-0 pr-10 muted d-flex align-items-center' title='More Options'>
            <EllipsisVertical size='2rem' />
          </button>
        </NestedDropdown>
      </div>
    </div>
    <div class='row mt-10'>
      <div class='col-12 col-sm-6 d-flex align-items-center justify-content-center justify-content-sm-start'>
        <div class='d-flex align-items-center mr-5' title='Toggle Autoplay'>
          <Timer size='2.75rem' class='position-absolute z-10 text-dark-light pl-10 pointer-events-none' />
          <button type='button' class='form-control w-full bg-dark-very-light pointer control text-nowrap {!$settings.rssAutoplay ? `pl-15` : `px-25`}' use:click={() => autoPlayToggle()}>
          <span class:ml-20={!$settings.rssAutoplay} class:ml-10={$settings.rssAutoplay}>
            {#if $settings.rssAutoplay}
              Autoplay [{countdown}]
            {:else}
              Autoplay [Off]
            {/if}
          </span>
          </button>
        </div>
        <div class='d-flex align-items-center mr-5' style='width: calc(5.2rem + {(String(episodeSearch).length <= 10 ? String(episodeSearch).length : 10) * 1}rem) !important' title='Episode'>
          <Clapperboard size='2.75rem' class='position-absolute z-10 text-dark-light pl-10 pointer-events-none' />
          <input type='number' inputmode='numeric' pattern='[0-9]*' max={maxEpisode} class='form-control bg-dark-very-light pl-40 control' placeholder='5' step='1' value={episodeSearch} on:input={episodeInput} disabled={(!search.episode && search.episode !== 0) || movie} />
        </div>
        {#if $debridTransport}
          <div class='d-flex align-items-center px-10 py-5 rounded border text-nowrap font-weight-bold' style='background: hsla(var(--primary-color-dim-hsl), .15); border-color: var(--primary-color-light) !important; color: var(--primary-color-light)' title={$debridTransport.description}>
            <Cloud size='1.8rem' class='mr-5' />
            {$debridTransport.label}
          </div>
        {/if}
        {#if $debridEnabled}
          <button type='button' class='btn d-flex align-items-center px-10 py-5 ml-5 rounded text-nowrap font-weight-bold flex-shrink-0' class:bg-dark-very-light={!cachedOnly} class:bg-primary={cachedOnly} use:click={() => $settings.debridCachedOnly = !$settings.debridCachedOnly}
               title={`Show only releases known to be cached on ${$debridTransport?.title ?? 'your debrid service'}, which play instantly.\n${availabilitySummary}`}>
            <Cloud size='1.8rem' class='mr-5' />
            Cached {queryResults?.counts?.cached ?? 0}{#if $debridChecking}<RefreshCw size='1.4rem' class='ml-5 spinning' />{/if}
          </button>
        {/if}
      </div>
      <div class='col-12 col-sm-6 d-flex align-items-center mt-5 justify-content-center mt-sm-0 justify-content-sm-end'>
        <div class='d-flex align-items-center mr-5' data-toggle='tooltip' data-placement='top' data-title='Scrape Peer Data'>
          <button type='button' class='btn btn-square bg-dark-very-light ml-auto d-flex align-items-center justify-content-center rounded-2 flex-shrink-0' use:click={handleScrape} disabled={!$results?.resolved || !$results?.torrents?.length || scraping}><Radio size='1.8rem' class={scraping ? 'pulsing' : ''} /></button>
        </div>
        <div class='d-flex align-items-center mr-5' data-toggle='tooltip' data-placement='top' data-title='Refresh Search Results'>
          <button type='button' class='btn btn-square bg-dark-very-light ml-auto d-flex align-items-center justify-content-center rounded-2 flex-shrink-0' use:click={() => queries = queryExtensions({...search}, resolution)} disabled={!$results?.resolved}><RefreshCw size='1.8rem' class={!$results?.resolved ? 'spinning' : ''} /></button>
        </div>
        <div class='d-flex align-items-center pr-5' title='Sorting Preference'>
          <ArrowDownWideNarrow size='2.75rem' class='position-absolute z-10 text-dark-light pl-10 pointer-events-none' />
          <select class='form-control w-full bg-dark-very-light pl-40 control' bind:value={$settings.torrentSort}>
            <option value='seeders' selected>Seeders</option>
            <option value='smallest' selected>Smallest</option>
            <option value='new' selected>Newest</option>
            <option value='old' selected>Oldest</option>
            <option value='batch' selected>Batch</option>
            <option value='best' selected>Best</option>
          </select>
        </div>
        <div class='d-flex align-items-center' title='Video Quality'>
          <MonitorCog size='2.75rem' class='position-absolute z-10 text-dark-light pl-10 pointer-events-none' />
          <select class='form-control w-full bg-dark-very-light pl-40 control' bind:value={$settings.rssQuality}>
            <option value='1080' selected>1080p</option>
            <option value='720'>720p</option>
            <option value='540'>540p</option>
            <option value='480'>480p</option>
            <option value=''>Any</option>
          </select>
        </div>
      </div>
    </div>
  </div>
  <div bind:this={container} class='scroll-container h-full px-30 overflow-y-scroll'>
    {#await errors then errorResult}
      {#if errorResult?.errorCardOnly && $results?.resolved && !$results?.torrents?.length}
        <div class='mt-80'>
          {hideErrors()}
          <ErrorCard promise={Promise.resolve(errorResult)} />
        </div>
      {/if}
    {/await}
    {#if $results?.torrents?.length && !$results?.resolved && ($results?.torrents?.length !== lookupHidden?.length) && (!best || !Object.values(best)?.length)}
      <TorrentCardSk />
    {:else if $results?.torrents?.length}
      {#if best}<TorrentCard type='best' countdown={$settings.rssAutoplay && $results?.resolved ? countdown : -1} result={best} {play} media={search.media} episode={search.episode} />{/if}
      {#if lastMagnet}
        {#each filterResults(lookup, searchText) as result}
          {#if ((result.link === lastMagnet.link) || (result.hash === lastMagnet.hash)) && (result.seeders ?? 0) > 1 && ((best?.link !== lastMagnet.link) && (best?.hash !== lastMagnet.hash)) }
            <TorrentCard type='magnet' result={result} {play} media={search.media} episode={search.episode} />
          {/if}
        {/each}
      {/if}
    {/if}
    {#each filterResults(lookup, searchText) as result}
      {#if ((best?.link !== result.link) && (best?.hash !== result.hash)) && (!lastMagnet || (((result.link !== lastMagnet.link) || (result.hash !== lastMagnet.hash)) || (result.seeders ?? 0) <= 1))}
        <TorrentCard {result} {play} media={search.media} episode={search.episode} />
      {/if}
    {/each}
    {#if queries}
      {#await queries then queries}
        {#each queries as [key, extension] (key)}
          {@const extensionName = `${(extension.name).slice(0, 25)}${extension?.name?.length > 25 ? '...' : ''}`}
          {#await extension.promise}
            <TorrentCardSk name={extensionName} icon={extension.icon || 'none'} />
          {:then resolved}
            {#if !resolved?.errors?.length}
              {addResults(resolved, { name: extensionName, icon: extension.icon })}
            {/if}
          {/await}
        {/each}
      {/await}
    {/if}
    {#if !$results?.resolved}
      {#each Array.from({ length: $results?.torrents?.length ? Math.max(15 - $results.torrents.length, 0) : 15 }) as _}
        <TorrentCardSk />
      {/each}
    {/if}
    {#if lookupHidden?.length && $results?.torrents?.length && filterResults(lookupHidden, searchText)?.length}
      <button type='button' class='long-button mb-10 control bd-highlight h-50 btn w-full p-5 rounded-3 d-flex align-items-center font-size-16 font-weight-semi-bold overflow-hidden' class:bg-dark={!viewHidden} class:bg-primary={viewHidden} use:click={()=> { viewHidden = !viewHidden }}>
        <span class='ml-20'>{lookupHidden?.length} {cachedOnly ? `Result${lookupHidden?.length > 1 ? 's' : ''} Not Cached` : `Unseeded Result${lookupHidden?.length > 1 ? 's' : ''} (Unavailable)`}</span>
        <svelte:component this={ viewHidden ? ChevronUp : ChevronDown } class='ml-auto mr-10' size='2.2rem' />
      </button>
      {#if viewHidden}
        {#each filterResults(lookupHidden, searchText) as result}
          {#if (!best || ((best.link !== result.link) && (best.hash !== result.hash))) && (!lastMagnet || (((result.link !== lastMagnet.link) || (result.hash !== lastMagnet.hash)) || (result.seeders ?? 0) <= 1))}
            <div class='unavailable'><TorrentCard {result} {play} media={search.media} episode={search.episode} /></div>
          {/if}
        {/each}
      {/if}
    {/if}
    {#if queries && !errorCardOnly}
      {#await queries then queries}
        {#each queries as [key, extension] (key)}
          {@const extensionName = `${(extension.name).slice(0, 25)}${extension?.name?.length > 25 ? '...' : ''}`}
          {#await extension.promise then resolved}
            {#if resolved?.errors?.length}
              <TorrentCard type='error' result={{ title: cleanErrorMessage(resolved.errors[0].message), source: { name: extensionName, icon: extension.icon } }} media={search.media} episode={search.episode} />
            {/if}
          {:catch error}
            <TorrentCard type='error' result={{ title: cleanErrorMessage(error?.message), source: { name: extensionName, icon: extension.icon } }} media={search.media} episode={search.episode} />
          {/await}
        {/each}
      {/await}
    {/if}
  </div>
</div>

<style>
  .unavailable {
    opacity: 0.6;
  }
  .controls::after {
    content: '';
    position: absolute;
    bottom: -2.2rem;
    left: 0;
    right: 0;
    height: 1.2rem;
    background: linear-gradient(to bottom, var(--dark-color-dim), transparent);
    pointer-events: none;
    z-index: 1;
  }
  .scroll-container :global(> *:first-child) {
    margin-top: 1rem !important;
  }
  .title {
    display: inline-block;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 100%;
    text-shadow: 2px 2px 4px hsla(var(--black-color-hsl), 1);
  }
  .mt-80 {
    margin-top: 8rem;
  }
  .px-25 {
    padding-left: 2.5rem;
    padding-right: 2rem;
  }
  :global(.pulsing) {
    animation: pulse 1.2s ease-in-out infinite;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: 0.4; }
  }
  :global(.spinning) {
    animation: spin 1s linear infinite;
  }
  @keyframes spin {
    from {
      transform: rotate(0deg);
    }
    to {
      transform: rotate(360deg);
    }
  }
</style>