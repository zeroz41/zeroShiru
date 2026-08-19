<script context='module'>
  import { click } from '@/modules/lib/click.js'
  import { matchPhrase } from '@/modules/util.js'
  import { settings } from '@/modules/settings.js'
  import { status } from '@/modules/networking.js'
  import { TORRENT } from '@/modules/bridge.js'
  import { loadingSession, loadedTorrent, completedTorrents, seedingTorrents, stagingTorrents } from '@/modules/torrent.js'
  import ErrorCard from '@/components/cards/ErrorCard.svelte'
  import TorrentCard from '@/routes/torrentManager/components/TorrentCard.svelte'
  import { Search, RefreshCw, TriangleAlert, Package, Percent, Activity, Scale, Gauge, CloudDownload, CloudUpload, Sprout, Magnet, Timer } from 'lucide-svelte'
</script>
<script>
  let containerEl
  let searchText = ''
  function filterResults(results, searchText) {
    const dedupe = results.filter((torrent, index, arr) => arr.findIndex(_torrent => _torrent.infoHash === torrent.infoHash) === index)
    if (!searchText?.length) return dedupe
    return dedupe.filter(({ name }) => matchPhrase(searchText, name, 0.4, false, true)) || []
  }
  function rescan() {
    if (disableRescan) return
    $loadingSession = true
    TORRENT.rescan().then(() => $loadingSession = false)
  }
  $: disableRescan = ($seedingTorrents?.length + $stagingTorrents?.length + 1) >= settings.value.seedingLimit && !settings.value.torrentPersist
  $: filteredLoaded = matchPhrase(searchText, $loadedTorrent?.name, 0.4, false, true)
  $: filteredStaging = filterResults($stagingTorrents, searchText) || []
  $: filteredSeeding = filterResults($seedingTorrents, searchText) || []
  $: filteredCompleted = filterResults($completedTorrents, searchText) || []
  $: foundResults = !(searchText?.length && !filteredLoaded && !filteredStaging.length && !filteredSeeding.length && !filteredCompleted.length)
</script>

<div class='root bg-dark d-flex flex-column h-full w-full overflow-y-scroll overflow-x-hidden'>
  <div class='header w-full status-transition pl-20 position-sticky top-0 bg-dark z-20 pb-10' class:mb-25={!disableRescan} class:pt-28px={!$status.match(/offline/i)} class:pt-15={$status.match(/offline/i)}>
    <h4 class='font-weight-bold m-0 mb-10'>Manage Torrents</h4>
    <div class='d-flex align-items-center'>
      <div class='input-group wm-600'>
        <Search size='2.6rem' strokeWidth='2.5' class='position-absolute z-10 text-dark-light h-full pl-10 pointer-events-none' />
        <input
          type='search'
          class='form-control bg-dark-very-light pl-40 rounded-1 h-40 text-truncate'
          autocomplete='off'
          spellcheck='false'
          data-option='search'
          placeholder='Filter torrents by text, or manually specify one by pasting a magnet link or torrent file' disabled={$loadingSession} bind:value={searchText} />
      </div>
      <button type='button' use:click={rescan} disabled={disableRescan || $loadingSession} title={disableRescan ? 'Enable Persist Files or Increase Seeding Limit' : $loadingSession ? 'Rescanning Cache...' : 'Rescan Cache'} class='btn btn-primary d-flex align-items-center justify-content-center ml-20 mr-20 font-scale-16 h-full' class:cursor-wait={$loadingSession}><RefreshCw class='mr-10' size='1.8rem' strokeWidth='2.5'/><span>Rescan</span></button>
    </div>
  </div>
  <div class='d-none' class:d-inline-block={disableRescan}>
    <div class='alert bg-warning border-warning-dim text-warning-very-dim p-10 pl-15 mb-25 mt-10 d-flex mx-20'>
      <TriangleAlert class='flex-shrink-0' size='1.8rem' />
      <span class='ml-10'>You've reached your pre-download limit. To pre-download more torrents, stop seeding some, increase your seeding limit, or enable Persist Files in Client Settings.</span>
    </div>
  </div>
  <div class='d-flex flex-column flex-1 w-full text-wrap text-break-word font-scale-16'>
    <div class='labels d-flex flex-row mb-10 font-scale-18 position-sticky bg-dark z-20 status-transition' style='top: calc(9rem + {!$status.match(/offline/i) ? `28px` : `1.5rem`})'>
      <div class='font-weight-bold p-5 ml-20 mw-150 flex-1 w-auto'>Name</div>
      <div class='font-weight-bold p-5 w-150 d-none d-md-block'><span class='d-none d-lg-block'>Size</span><Package class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150'><span class='d-none d-lg-block'>Progress</span><Percent class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150'><span class='d-none d-lg-block'>Status</span><Activity class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150 d-none d-md-block'><span class='d-none d-lg-block'>Ratio</span><Scale class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150 d-none d-md-block'><span class='d-none d-lg-block'>Down Speed</span><CloudDownload class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150 d-block d-md-none'><span class='d-none d-lg-block'>Speed</span><Gauge class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150 d-none d-md-block'><span class='d-none d-lg-block'>Up Speed</span><CloudUpload class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150'><span class='d-none d-lg-block'>Seeders</span><Sprout class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-150 d-none d-md-block'><span class='d-none d-lg-block'>Leechers</span><Magnet class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-115 d-none d-md-block'><span class='d-none d-lg-block'>ETA</span><Timer class='d-lg-none' size='2rem'/></div>
      <div class='font-weight-bold p-5 w-40 mr-5 mr-md-20 flex-shrink-0'/>
    </div>
    <div class='flex-1' bind:this={containerEl}>
      {#if foundResults}
        {#if !searchText?.length || filteredLoaded}
          <TorrentCard bind:data={$loadedTorrent} current={true} {disableRescan} {containerEl} />
        {/if}
        {#each filteredStaging as torrent (torrent.infoHash)}
          <TorrentCard data={torrent} {disableRescan} {containerEl} />
        {/each}
        {#each filteredSeeding as torrent (torrent.infoHash)}
          <TorrentCard data={torrent} {disableRescan} {containerEl} />
        {/each}
        {#each filteredCompleted as torrent (torrent.infoHash)}
          <TorrentCard data={torrent} completed={true} {disableRescan} {containerEl} />
        {/each}
      {:else}
        <ErrorCard promise={{ errors: [ { message: 'found no results' }]}}/>
      {/if}
    </div>
  </div>
</div>

<style>
  .header::after,
  .labels::after {
    content: '';
    position: absolute;
    bottom: -1.2rem;
    left: 0;
    right: 0;
    height: 1.2rem;
    background: linear-gradient(to bottom, var(--dark-color), transparent);
    pointer-events: none;
    z-index: 1;
  }
</style>