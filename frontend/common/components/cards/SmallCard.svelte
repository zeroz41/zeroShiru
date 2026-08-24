<script>
  import { onMount, onDestroy } from 'svelte'
  import PreviewCard from '@/components/cards/PreviewCard.svelte'
  import { airingAt, getAiringInfo, formatMap, statusColorMap } from '@/modules/anime/anime.js'
  import { createListener, baseFontSize, resizeObserver, minuteTick, railCover } from '@/modules/util.js'
  import { hoverClick } from '@/modules/lib/click.js'
  import { createHoverIntent, FOCUS_DWELL } from '@/modules/lib/hover.js'
  import SmartImage from '@/components/visual/SmartImage.svelte'
  import AudioLabel from '@/components/AudioLabel.svelte'
  import { anilistClient, currentYear } from '@/modules/providers/anilist/anilist.js'
  import { settings } from '@/modules/settings.js'
  import { mediaCache, fromCache } from '@/modules/cache.js'
  import { modal } from '@/modules/navigation.js'
  import { CalendarDays, Tv, ThumbsUp, ThumbsDown } from 'lucide-svelte'

  /** @type {import('@/modules/providers/anilist/al.d.ts').Media} */
  export let data
  export let type = null
  export let variables = null
  let _variables = variables

  let media
  $: media = fromCache($mediaCache, media ?? mediaCache.value[data?.id])
  function viewMedia() {
    if (_variables?.fileEdit) _variables.fileEdit(media)
    else modal.open(modal.ANIME_DETAILS, media)
  }

  const { reactive, init } = createListener(['btn', 'scoring', 'mute', 'preview-safe-area'])
  $: init(preview)
  $: if (preview) clearTimeout(focusTimeout)

  let preview = false
  let ignoreFocus = false
  // a pointer crossing the grid must not open (and pay for) a preview per card it passes
  const hoverIntent = createHoverIntent({ apply: value => { preview = value } })
  function setHoverState(state, tapped) {
    const focused = document.activeElement
    if (container && focused?.offsetParent != null && (container.contains(focused)) && (!previewCard || !previewCard.contains(focused))) ignoreFocus = true
    if (settings.value.cardPreview) hoverIntent.set(state, tapped)
    else if (state) viewMedia()
  }

  let container
  let previewCard
  let focusTimeout
  let blurTimeout
  function handleFocus() {
    if (ignoreFocus || preview) return
    clearTimeouts()
    focusTimeout = setTimeout(() => {
      if (settings.value.cardPreview) {
        preview = true
        ignoreFocus = true
        document.addEventListener('pointerup', handleOutsideClick)
      }
    }, FOCUS_DWELL)
    focusTimeout.unref?.()
  }
  function handleBlur() {
    clearTimeouts()
    blurTimeout = setTimeout(() => {
      const focused = document.activeElement
      const lostFocus = container && focused?.offsetParent != null && !container.contains(focused)
      const lostPreviewFocus = previewCard && !previewCard.contains(focused)
      if (lostFocus && lostPreviewFocus) {
        preview = false
        ignoreFocus = false
        document.removeEventListener('pointerup', handleOutsideClick)
      } else if (lostFocus || (previewCard && previewCard.contains(focused))) ignoreFocus = false
    })
    blurTimeout.unref?.()
  }
  function handleOutsideClick(event) {
    if (container && previewCard && !container.contains(event.target) && !previewCard.contains(event.target)) {
      preview = false
      ignoreFocus = false
      document.removeEventListener('pointerup', handleOutsideClick)
    }
  }
  function clearTimeouts() {
    clearTimeout(focusTimeout)
    clearTimeout(blurTimeout)
    hoverIntent.cancel()
  }

  let baseWidth
  let imageWidth
  $: baseWidth = 19 * $baseFontSize
  $: scale = Math.max(imageWidth && baseWidth ? Math.min(imageWidth / baseWidth, .9) : .9, .75)
  const trackWidth = resizeObserver((_, entry) => {
    const width = entry.contentRect.width
    if (Math.abs(width - imageWidth) < 1) return
    imageWidth = width
  })

  let _airingAt = null
  // $minuteTick only forces the re-derive: one shared clock for every countdown on
  // screen, instead of the interval per card (~50 on a schedule page) this used to run
  $: airingInfo = ($minuteTick, getAiringInfo(_airingAt))
  onMount(() => {
    container.addEventListener('focusout', handleBlur)
    _airingAt = media && _variables?.scheduleList && airingAt(media, _variables)
  })
  onDestroy(() => {
    document.removeEventListener('pointerup', handleOutsideClick)
    container?.removeEventListener?.('focusout', handleBlur)
    clearTimeouts()
  })
</script>

<div bind:this={container} class='d-flex px-md-20 px-sm-10 px-5 py-20 position-relative small-card-ct' class:not-reactive={!$reactive} class:lift-parent={$reactive} use:hoverClick={[viewMedia, setHoverState, viewMedia]} on:focus={handleFocus}>
  {#if preview}
    <PreviewCard {media} {type} {_variables} bind:element={previewCard}/>
  {/if}
  <div class='item small-card d-flex flex-column pointer' class:airing={airingInfo?.episode.match(/out for/i)}>
    {#if airingInfo}
      <div class='w-full text-center pb-10'>
        {airingInfo.episode}&nbsp;
        <span class='font-weight-bold {airingInfo.episode.match(/out for/i) ? `text-success` : `text-light`}'>
            {airingInfo.time}
        </span>
      </div>
    {/if}
    <div use:trackWidth class='d-inline-block position-relative mb-5 rounded lift' style:--lift-color={media.coverImage?.color || 'var(--tertiary-color)'}>
      <span class='airing-badge rounded-10 font-weight-semi-bold text-light bg-success' class:d-none={!airingInfo?.episode?.match(/out for/i)}>AIRING</span>
      <SmartImage eager={!!_variables?.section} class='d-inline-block cover-img cover-ratio w-full h-full rounded' color={media.coverImage?.color || 'var(--tertiary-color)'} images={[...railCover(media.coverImage), './no_image_cover.jpg']}/>
      {#if !_variables?.scheduleList}
        <AudioLabel {media} style='transform: scaleY(-1) scale({scale}) !important; transform-origin: right !important; width: {100 / scale}% !important; bottom: {.4 * scale}rem !important;' />
      {/if}
    </div>
    {#if type || type === 0}
      <div class='context-type d-flex align-items-center'>
        {#if Number.isInteger(type) && type >= 0}
          <ThumbsUp fill='currentColor' class='pr-5 pb-5 {type === 0 ? `text-muted` : `text-success`}' size='2rem' />
        {:else if Number.isInteger(type) && type < 0}
          <ThumbsDown fill='currentColor' class='text-danger pr-5 pb-5' size='2rem' />
        {/if}
        {(Number.isInteger(type) ? Math.abs(type).toLocaleString() + (type >= 0 ? ' like' : ' dislike') + ((type !== 1 && type !== -1) ? 's' : '') : type)}
      </div>
    {/if}
    <div class='text-white font-weight-very-bold font-size-16 title overflow-hidden' class:mb-10={type || type === 0}>
      {#if media.mediaListEntry?.status}
        <div style:--statusColor={statusColorMap[media.mediaListEntry.status]} class='list-status-circle d-inline-flex overflow-hidden mr-5' title={media.mediaListEntry.status} />
      {/if}
      {anilistClient.title(media)}
    </div>
    <div class='d-flex flex-row mt-auto font-weight-medium justify-content-between w-full text-muted'>
      <div class='d-flex align-items-center pr-5'>
        <CalendarDays class='pr-5' size='2.6rem' />
        <span class='line-height-1'>{media.seasonYear || media.startDate?.year || (media.status === 'NOT_YET_RELEASED' && 'TBA') || (media.status === 'RELEASING' && currentYear) || 'N/A'}</span>
      </div>
      <div class='d-flex align-items-center text-nowrap text-right'>
        <span class='line-height-1'>{formatMap[media.format]}</span>
        <Tv class='pl-5' size='2.6rem' />
      </div>
    </div>
  </div>
</div>

<style>
  /* the ring is drawn once and then only moved and faded: an animated box-shadow is
     repainted by the CPU every frame, and a schedule full of airing cards means every
     one of them repainting forever, which is felt everywhere else on the page */
  .airing::before {
    content: '';
    position: absolute;
    inset: -1.3rem;
    border-radius: .4rem;
    pointer-events: none;
    box-shadow: 0 0 0 .7rem var(--dark-color);
    animation: airing-pulse 3.5s infinite;
    will-change: transform, opacity;
  }
  @keyframes airing-pulse {
    0%   { transform: scale(.955); opacity: 0.9; }
    25%  { transform: scale(1); opacity: 0.6; }
    40%  { transform: scale(1); opacity: 0.4; }
    100% { transform: scale(1.01); opacity: 0; }
  }
  .airing-badge {
    position: absolute;
    top: -1rem;
    right: -1rem;
    font-size: 1rem;
    padding: .35rem .9rem;
    box-shadow: 0 .2rem .5rem hsla(var(--black-color-hsl), 0.2);
  }
  .small-card-ct:hover {
    z-index: 30;
    /* fixes transform scaling on click causing z-index issues */
  }
  .title {
    display: -webkit-box;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    line-height: 1.2;
  }
  .item {
    width: 100%;
    aspect-ratio: 152/296;
    box-sizing: border-box;
    padding: .65rem;
    border: .1rem solid var(--surface-border);
    border-radius: 1.25rem;
    background: linear-gradient(165deg, var(--surface-panel), hsla(var(--dark-color-hsl), .72));
    box-shadow: 0 .8rem 2rem hsla(var(--black-color-hsl), .22);
    /* a small, immediate answer to the pointer, on the `translate` property rather than
       `transform` so nothing that positions itself with a transform is disturbed. The
       shadow that comes with it is the .lift layer on the poster — see css.css */
    transition: translate var(--motion) var(--ease-settle), border-color var(--motion) var(--ease-settle), background-color var(--motion) var(--ease-settle);
  }
  .small-card-ct:not(.not-reactive):hover .item {
    translate: 0 -.5rem;
    border-color: hsla(var(--tertiary-color-hsl), .42);
    /* the brighten rides a background-color layer under the (unchanged) gradient:
       gradients don't interpolate, so swapping them snapped while translate glided */
    background-color: hsla(var(--dark-color-light-hsl), .8);
  }
  .small-card-ct:not(.not-reactive):active .item {
    translate: 0 0;
    transition: translate var(--motion-press) var(--ease-press);
  }
  .list-status-circle {
    background: var(--statusColor);
    height: 1.1rem;
    width: 1.1rem;
    border-radius: 50%;
  }
</style>
