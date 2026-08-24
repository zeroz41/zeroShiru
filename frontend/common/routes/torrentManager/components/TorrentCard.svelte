<script>
  import { Database, Clapperboard, Projector, EllipsisVertical } from 'lucide-svelte'
  import { onDestroy, onMount } from 'svelte'
  import { settings } from '@/modules/settings.js'
  import { fastPrettyBytes } from '@/modules/util.js'
  import { add, stage, unload, untrack, complete } from '@/modules/torrent.js'
  import { click } from '@/modules/lib/click.js'
  import { eta, createListener } from '@/modules/util.js'
  import { mediaCache } from '@/modules/cache.js'
  import NestedDropdown from '@/components/overlays/NestedDropdown.svelte'
  import { anilistClient } from '@/modules/providers/anilist/anilist.js'
  import AnimeResolver from '@/modules/anime/animeresolver.js'
  import { copyToClipboard } from '@/modules/lib/clipboard.js'
  import { getId } from '@/modules/anime/animehash.js'
  import { modal } from '@/modules/navigation.js'

  export let data
  export let current = false
  export let completed = false
  export let disableRescan = false
  export let containerEl

  const infoHash = data.infoHash

  function ratioType(ratio, progress) {
    if ((Math.round(ratio * 100) / 100 <= 0 || progress < 1) && !data.incomplete) return 'Leeching'
    else if (ratio < 0.5) return 'Leecher'
    else if (ratio < 1.0) return 'Fair'
    else if (ratio < 2.5) return 'Good'
    return 'Seeder'
  }

  let resolved
  $: resolvedInfo = data.infoHash
  $: resolved = getResolvedId(resolvedInfo)
  const onFileEdit = () => { resolved = getResolvedId(data.infoHash) }
  window.addEventListener('fileEdit', onFileEdit)
  function getResolvedId(infoHash) {
    return getId(infoHash, { client: true }, true)
  }

  $: resolvedId = resolved?.mediaId
  $: episode = resolved?.files?.length <= 1 ? !resolved?.files?.length ? resolved?.episode : (Number.isFinite(Number(resolved?.files?.[0]?.episode)) ? Number(resolved?.files?.[0]?.episode) : resolved?.episode) : null
  $: episodeRange = resolved?.files?.length <= 1 ? !resolved?.files?.length ? (resolved?.episodeRange && `${resolved.episodeRange.first} ~ ${resolved.episodeRange.last}`) : (resolved?.files?.[0]?.episodeRange && `${resolved?.files?.[0].episodeRange.first} ~ ${resolved?.files?.[0].episodeRange.last}`) || (resolved?.episodeRange && `${resolved.episodeRange.first} ~ ${resolved.episodeRange.last}`) : null
  $: search = $mediaCache[resolvedId] ? { media: $mediaCache[resolvedId], episode, episodeRange  } : null

  function viewMedia() {
    modal.open(modal.ANIME_DETAILS, $mediaCache[resolvedId])
  }

  function altClick() {
    if (resolvedId && $mediaCache[resolvedId]) viewMedia()
    else if (completed) stage(infoHash, null, infoHash)
    else if (data.progress === 1) complete(infoHash)
  }

  let viewOptions = false
  const { reactive, init } = createListener([`react-${infoHash}`])
  onMount(() => init(true))
  onDestroy(() => {
    init(false, true)
    window.removeEventListener('fileEdit', onFileEdit)
  })
</script>
<div role='button' tabindex='0' style:--progress={(!completed && data.progress) || 0} class='details mx-10 mb-10 py-20 text-wrap text-break-word d-flex' class:not-reactive={!$reactive || current || viewOptions} class:bg-error={completed && data.incomplete} class:current={current} class:option={!current} class:pointer={!current} class:not-allowed={current} aria-label={!current ? 'Play Torrent' : 'Currently Playing'} title={!current ? 'Play Torrent' : 'Currently Playing'} use:click={() => { if (!current) add(infoHash, search, infoHash) }} on:contextmenu|preventDefault={altClick}>
  <div class='d-flex flex-row w-full load-in mw-0'>
    <div class='p-5 ml-20 name mw-150 flex-1 w-auto d-flex flex-column'>
      {#if resolvedId && $mediaCache[resolvedId]}
        <div class='font-weight-bold line-2 overflow-hidden d-flex align-items-center justify-content-center' title={`${anilistClient.title($mediaCache[resolvedId])}${(episode || episode === 0) ? ` Episode ${episode}` : ``}`}>
          {#if episodeRange || episode || episode === 0}
            <span class='mr-2 d-inline-flex align-items-center justify-content-center align-middle bg-primary-dim px-3 rounded mb-5' title={`Episode ${episodeRange || episode}`}><Clapperboard size='2rem' class='mr-5'/><span class='mt-2 mr-2'>{episodeRange || episode}</span></span>
          {:else if $mediaCache[resolvedId]?.format === 'MOVIE'}
            <span class='mr-2 d-inline-flex align-items-center align-middle bg-primary-dim px-3 py-3 rounded mb-5' title='Movie'><Projector size='2rem'/></span>
          {:else}
            <span class='mr-2 d-inline-flex align-items-center align-middle bg-primary-dim px-3 py-3 rounded mb-5' title='Batch'><Database size='2rem'/></span>
          {/if}
          <span>{anilistClient.title($mediaCache[resolvedId])}</span>
        </div>
      {/if}
      <div class='text-muted line-2 overflow-hidden' title={data.name && AnimeResolver.cleanFileName(data.name)}>{(data.name && AnimeResolver.cleanFileName(data.name)) || '—'}</div>
    </div>
    <div class='p-5 w-150 d-none d-md-block'>{fastPrettyBytes(data.size)}</div>
    <div class='p-5 w-150'>{data.size && !data.missing_pieces ? `${((data.progress * 100) || 0).toFixed(1)}%` : (data.missing_pieces ? '—' : '0.0%')}</div>
    <div class='p-5 w-150'>{completed ? (data.incomplete ? (data.missing_pieces ? 'Missing Pieces' : 'Incomplete') : 'Completed') : data.progress === 1 ? 'Seeding' : data.size && (data.downloadSpeed || data.uploadSpeed) ? 'Downloading' : !(data.downloadSpeed || data.uploadSpeed) && data.eta > 1000 && data.eta < Infinity && data.progress < 1 && !settings.value.torrentStreamedDownload ? 'Scanning' : data.name ? 'Stalled' : '—'}</div>
    <div class='p-5 w-150 d-none d-md-block'>{!completed && data.name && (data.progress ? ((Math.ceil((data.ratio || 0) * 100) / 100)?.toFixed(2)) : '0.00') || (data.incomplete && !data.missing_pieces ? '0.01' : '—')}<span class='text-muted text-nowrap' class:d-none={(completed && (!data.incomplete || data.missing_pieces)) || !data.name}>{` (${ratioType(data.ratio || 0, data.progress)})`}</span></div>
    <div class='p-5 w-150'>{completed ? '—' : `${fastPrettyBytes(data.downloadSpeed || 0)}/s`}</div>
    <div class='p-5 w-150 d-none d-md-block'>{completed ? '—' : `${fastPrettyBytes(data.uploadSpeed || 0)}/s`}</div>
    <div class='p-5 w-150'>{completed ? '—' : data.numSeeders || 0}<span class='text-muted text-nowrap' class:d-none={completed}>{` (${data.totalSeeders || 0})`}</span></div>
    <div class='p-5 w-150 d-none d-md-block'>{completed ? '—' : data.numLeechers || 0}<span class='text-muted text-nowrap' class:d-none={completed}>{` (${data.numPeers || 0})`}</span></div>
    <div class='p-5 w-115 d-none d-md-block'>{data.eta > 0 && data.progress < 1 ? eta(new Date(Date.now() + data.eta)) : '∞'}</div>
  </div>
  <div class='react-{infoHash} mr-5 mr-md-20 w-40 h-auto' class:d-none={!infoHash}>
    <NestedDropdown title='Options' direction='left' alignStart={true} panelWidth={20} panelHeightPadding={6} {containerEl} bind:isOpen={viewOptions} items={[
        ...(!current && infoHash ? [{
          label: 'Play',
          close: true,
          onSelect: () => add(infoHash, search, infoHash)
        }] : []),
        ...(infoHash ? [{
          label: 'Untrack',
          close: true,
          onSelect: () => untrack(infoHash)
        }] : []),
        ...(completed && data.incomplete && settings.value.seedingLimit > 1 && !disableRescan && infoHash ? [{
          label: 'Resume',
          close: true,
          onSelect: () => stage(infoHash, null, infoHash)
        }] : []),
        ...(current && infoHash ? [{
          label: 'Stop Playing',
          close: true,
          onSelect: () => unload()
        }] : []),
        ...(!completed && !current && data.progress < 1 && settings.value.torrentPersist && infoHash ? [{
          label: 'Stop Download',
          close: true,
          onSelect: () => complete(infoHash)
        }] : []),
        ...(!completed && !current && data.progress === 1 && settings.value.torrentPersist && infoHash ? [{
          label: 'Stop Seeding',
          close: true,
          onSelect: () => complete(infoHash)
        }] : []),
        ...(completed && !data.incomplete && settings.value.seedingLimit > 1 && !disableRescan && infoHash ? [{
          label: 'Start Seeding',
          close: true,
          onSelect: () => stage(infoHash, null, infoHash)
        }] : []),
        { type: 'separator' },
        ...(resolvedId && $mediaCache[resolvedId] ? [{
          label: 'View Media',
          close: true,
          onSelect: () => viewMedia()
        }] : []),
        ...(data.magnetURI ? [{
          label: 'Copy Magnet',
          close: true,
          onSelect: () => copyToClipboard(data.magnetURI, 'magnet URL')
        }] : [])
      ]}>
      <span class='btn btn-square h-full bg-transparent shadow-none border-0 options d-flex align-items-center muted justify-content-center flex-shrink-0 w-40' title='Options'>
        <EllipsisVertical size='2rem' />
      </span>
    </NestedDropdown>
  </div>
</div>
<style>
  .py-3 {
    padding-top: .3rem;
    padding-bottom: .3rem;
  }
  .px-3 {
    padding-left: .3rem;
    padding-right: .3rem;
  }
  .mr-2 {
    margin-right: 0.2rem;
  }
  .details {
    border: .1rem solid var(--surface-border);
    border-radius: var(--radius-panel);
    /* the first layer is the progress wash: a faint accent fill that grows with the
       download, painted as a background layer so no extra element fights the dropdown
       for stacking or positioning */
    background:
      linear-gradient(90deg, hsla(var(--tertiary-color-hsl), .08), hsla(var(--tertiary-color-hsl), .08)) left / calc(var(--progress, 0) * 100%) 100% no-repeat,
      linear-gradient(165deg, var(--surface-panel), hsla(var(--dark-color-hsl), .6));
    transition: border-color var(--motion) var(--ease-settle), filter var(--motion) var(--ease-settle);
  }
  /* the playing row wears the accent as a seated tab and a settled border,
     not a flat 1px outline */
  .current {
    border-color: hsla(var(--white-color-hsl), .16);
    box-shadow: inset .45rem 0 0 var(--quaternary-color);
  }
  @media (hover: hover) and (pointer: fine) {
    .option:hover {
      border-color: hsla(var(--tertiary-color-hsl), .42);
      /* keep both gradient layers unchanged; swapping either image snaps */
      filter: brightness(1.12);
    }
  }
</style>
