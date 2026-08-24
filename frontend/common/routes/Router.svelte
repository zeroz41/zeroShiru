<script>
  import HomePage from '@/routes/home/HomePage.svelte'
  import MediaHandler, { nowPlaying as media } from '@/components/MediaHandler.svelte'
  import SettingsPage from '@/routes/settings/SettingsPage.svelte'
  import WatchTogetherPage from '@/routes/w2g/WatchTogetherPage.svelte'
  import SchedulePage from '@/routes/SchedulePage.svelte'
  import TorrentPage from '@/routes/torrentManager/TorrentPage.svelte'
  import Miniplayer from '@/components/Miniplayer.svelte'
  import SearchPage from '@/routes/search/SearchPage.svelte'
  import { writable } from 'simple-store-svelte'
  import { search, key } from '@/modules/sections.js'
  import { page, modal, playPage } from '@/modules/navigation.js'

  export let statusTransition = false

  const playbackPaused = writable(true)
  const miniplayerShelved = writable(false)

  $: visible = !$modal[modal.TORRENT_MENU] && !$modal[modal.NOTIFICATIONS] && !$modal[modal.PROFILE] && !$modal[modal.MINIMIZE_PROMPT] && !$modal[modal.TRAILER] && !$playPage && !$media?.display
  $: miniplayer = ($media && (Object.keys($media).length > 0)) && (($page !== page.PLAYER && visible) || ($modal[modal.ANIME_DETAILS] && visible))

  /** Search mounts on first visit and stays mounted after — see the page hosts below. */
  let searchVisited = false
  $: if ($page === page.SEARCH) searchVisited = true
  // a file-edit search is a one-shot: leaving the page clears it, which used to happen
  // in SearchPage's onDestroy — a hook a kept-alive page never fires
  $: if ($page !== page.SEARCH && $search?.disableSearch) $search = { format: [], format_not: [], status: [], status_not: [] }
</script>
<div class='w-full h-full position-absolute overflow-hidden' class:invisible={!($media && (Object.keys($media).length > 0)) || ($playPage && $modal[modal.ANIME_DETAILS]) || (!visible && ($page !== page.PLAYER))}>
  <Miniplayer active={miniplayer} bind:playbackPaused={$playbackPaused} bind:shelved={$miniplayerShelved} class='bg-dark-light rounded-10 {($page === page.PLAYER && !$modal[modal.ANIME_DETAILS]) ? `h-full` : ``}' >
    <MediaHandler {miniplayer} bind:playbackPaused={$playbackPaused} bind:miniplayerShelved={$miniplayerShelved} />
  </Miniplayer>
</div>

<!-- Home and Search keep their DOM across navigation. Destroying them per switch threw
     away every painted image and every scroll position, and rebuilding the grids was
     most of what pop-in on navigation WAS. They mount on first visit and then only hide;
     kept pages reappear instantly, which needs no entry fade to soften. -->
<div class='page-host' class:page-parked={$page !== page.HOME}>
  <HomePage />
</div>
{#if searchVisited}
  <div class='page-host' class:page-parked={$page !== page.SEARCH}>
    <SearchPage search={search} key={key}/>
  </div>
{/if}
{#key $page}
  <!-- display:contents leaves layout exactly as it was; the entry fade lands on the
       page's own root box. Opacity only — a hard cut between pages was the last
       unanimated interaction in the app's chrome. -->
  <div class='page-host'>
    {#if $page === page.SETTINGS}
      <SettingsPage bind:statusTransition/>
    {:else if $page === page.SCHEDULE}
      <SchedulePage />
    {:else if $page === page.WATCH_TOGETHER}
      <WatchTogetherPage />
    {:else if $page === page.TORRENT_MANAGER}
      <TorrentPage />
    {/if}
  </div>
{/key}

<style>
  .page-host {
    display: contents;
  }
  /* a parked page keeps its DOM — its images, its scroll, its observers — and just
     leaves the layout until its tab comes back */
  .page-host.page-parked {
    display: none;
  }
  .page-host > :global(*) {
    animation: page-fade 0.18s ease-out;
  }
  @keyframes page-fade {
    from { opacity: 0.4; }
    to { opacity: 1; }
  }
</style>