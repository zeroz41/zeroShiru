<script context='module'>
  const defaultLength = 15
  const loadableLength = 50
  const fakecards = Array.from({ length: loadableLength }, () => ({ data: new Promise(() => {}) }))
</script>

<script>
  import Card from '@/components/cards/Card.svelte'
  import ErrorCard from '@/components/cards/ErrorCard.svelte'
  import { page } from '@/modules/navigation.js'
  import { search } from '@/modules/sections.js'
  import { click, dragScroll } from '@/modules/lib/click.js'
  import { SUPPORTS } from '@/modules/support.js'
  import { settings } from '@/modules/settings.js'
  import { resizeObserver, baseFontSize } from '@/modules/util.js'
  import { AHEAD_SECTIONS, nearViewport } from '@/modules/preload.js'
  import { onDestroy } from 'svelte'
  import { ChevronLeft, ChevronRight } from 'lucide-svelte'

  export let lastEpisode = false
  export let index = 0
  export let opts

  const preview = opts.preview
  const containerWidth = window.innerWidth / baseFontSize.value
  const cardWidthMap = {
    small: 19 + 5,
    full: Math.min(52, containerWidth * .88) + 5,
    episode: 36 + 5
  }
  const cardWidth = cardWidthMap[opts.isRSS ? 'episode' : ($settings.cards || 'small')] || cardWidthMap.small
  let previewLength = Math.floor(containerWidth / cardWidth) + 1 || defaultLength
  let sectionVisible = index < 3
  // A rail has at most 50 lightweight card shells. Mount it once, before the vertical
  // viewport arrives, and never mutate its DOM during a horizontal fling. Incremental
  // growth was visible as cards appearing under the pointer and made Svelte reconcile a
  // row in the hottest part of scrolling. The images are correctly sized and pinned;
  // section cards ask them to preload while this rail is still offscreen.
  const visibleLength = loadableLength

  // Starts the row's media query well before the row is reached, rooted at the page scroller
  // so the distance counts for anything at all — see modules/preload.js.
  const deferredLoad = (element) => nearViewport(element, {
    margin: AHEAD_SECTIONS,
    near () {
      sectionVisible = true
      if (!opts.preview.value) opts.preview.value = opts.load(1, loadableLength, { ...opts.variables })
    }
  })

  function _click () {
    $search = { ...opts.variables, load: opts.load, title: opts.title, clearNext: true }
    page.navigateTo(page.SEARCH)
  }

  let activeScroll = false
  function scrolling(duration = 1000) {
    activeScroll = true
    setTimeout(() => activeScroll = false, duration)
  }

  let scrollContainer
  function scrollCarousel(direction) {
    if (activeScroll) return
    if (direction === 'right' && (scrollContainer.scrollLeft + 2) >= (scrollContainer.scrollWidth - scrollContainer.clientWidth)) {
      scrolling()
      scrollContainer.scrollTo({ left: 0, behavior: 'smooth' })
    } else if (direction === 'left' && scrollContainer.scrollLeft <= 0) {
      setTimeout(() => {
        scrolling()
        scrollContainer.scrollTo({ left: (scrollContainer.scrollWidth - scrollContainer.clientWidth), behavior: 'smooth' })
      })
    } else {
      setTimeout(() => {
        scrolling(500)
        const scrollAmount = scrollContainer.offsetWidth
        scrollContainer.scrollBy({ left: direction === 'right' ? scrollAmount : -scrollAmount, behavior: 'smooth' })
      })
    }
  }

  let timeout
  const trackSectionWidth = resizeObserver((node) => {
    clearTimeout(timeout)
    timeout = setTimeout(() => {
      // querySelector, not querySelectorAll: a NodeList has no offsetWidth, so this
      // computed NaN and every row silently fell back to the default length
      const cardItem = node.querySelector('.small-card-ct, .full-card-ct, .episode-card')
      if (cardItem?.offsetWidth) {
        previewLength = Math.floor(node.offsetWidth / cardItem.offsetWidth) + 1
      }
    }, 15)
  })

  onDestroy(() => {
    clearTimeout(timeout)
  })
</script>

<span class='d-flex px-20 align-items-end text-decoration-none' class:mv-10={lastEpisode} use:deferredLoad>
  <div class='section-title font-scale-24 font-weight-bold glow pointer' aria-hidden='true' use:click={_click}>{opts.title}</div>
  <div class='ml-auto pr-5 pl-5 font-size-12 glow text-muted pointer btn d-none align-items-center justify-content-center' class:d-flex={!SUPPORTS.isAndroid} aria-hidden='true' use:click={() => scrollCarousel('left')}><ChevronLeft strokeWidth='3' size='2rem' /></div>
  <div class='pr-5 pl-5 ml-10 font-size-12 glow text-muted pointer btn d-none align-items-center justify-content-center' class:d-flex={!SUPPORTS.isAndroid} aria-hidden='true' use:click={() => scrollCarousel('right')}><ChevronRight strokeWidth='3' size='2rem' /></div>
</span>
<div class='position-relative' class:isRSS={opts.isRSS}>
  <div class='pb-10 w-full d-flex flex-row justify-content-start gallery {!opts.isRSS ? `pl-15 pl-sm-10 pl-md-0` : ``}' class:pt-10={!opts.isRSS && $settings.cards === `full`} use:dragScroll use:trackSectionWidth bind:this={scrollContainer}>
    <Card card={($preview || fakecards)[0]} variables={{...opts.variables, section: true}} />
    {#if sectionVisible}
      <!-- keyed by SLOT, not by wrapper identity: every refresh path builds a brand new
           array of wrappers, and keying on them destroyed and recreated every card — and
           every painted image — for a refresh that usually changes nothing -->
      {#each ($preview || fakecards).slice(1, visibleLength) as card, slot (slot)}
        <Card {card} variables={{...opts.variables, section: true}} />
      {/each}
    {/if}
    {#if $preview?.length}
      <ErrorCard promise={$preview[0].data} class='{opts.isRSS ? `mb-90` : ``}' />
    {/if}
  </div>
</div>

<style>
  /* rail titles own their row now: full-strength text seated on an accent tab,
     instead of the muted gray that made every section read as secondary */
  .section-title {
    color: var(--highlight-color);
    display: flex;
    align-items: center;
    transition: color var(--motion) var(--ease-settle);
  }
  .section-title::before {
    content: '';
    width: 0.45rem;
    height: 1.05em;
    margin-right: 1rem;
    border-radius: 5rem;
    background: linear-gradient(180deg, var(--tertiary-color-light), var(--tertiary-color));
  }
  @media (hover: hover) and (pointer: fine) {
    .section-title:hover {
      color: var(--tertiary-color-very-light);
    }
  }
  .btn {
    border-radius: 2rem;
  }
  .gallery :global(.small-card-ct:first-child) :global(.absolute-container) {
    left: -45% !important;
  }
  .gallery :global(.small-card-ct:last-child):not(:only-child) :global(.absolute-container) {
    right: -45% !important;
  }

  @media (max-width: 768px) {
    .gallery :global(.small-card-ct:first-child) :global(.absolute-container) {
      left: -35% !important;
    }
    .gallery :global(.small-card-ct:last-child:not(:only-child)) :global(.absolute-container) {
      right: -35% !important;
    }
  }
  @media (hover: hover) and (pointer: fine) {
    .glow:hover {
      color: var(--dm-link-text-color-hover) !important;
    }
  }
  .position-relative.isRSS .gallery::after {
    height: calc(100% - 10rem) !important;
    z-index: 1;
  }
  .gallery:after {
    content: '';
    position: absolute;
    right: 0;
    height: 100%;
    width: 8rem;
    z-index: 30;
    background: var(--section-end-gradient);
    pointer-events: none;
  }
  .gallery {
    overflow-x: scroll;
    overflow-y: hidden;
    overscroll-behavior-inline: contain;
    scrollbar-width: none;
    flex-shrink: 0;
    min-height: 25rem;
    cursor: grab;
  }
  .mv-10 {
    margin-top: -10rem !important;
    z-index: 0 !important;
  }
  .gallery :global(.item.small-card) {
    width: 19rem !important;
  }
  .gallery::-webkit-scrollbar {
    display: none;
  }
</style>
