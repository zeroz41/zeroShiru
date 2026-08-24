<script>
  import { Earth, WifiOff } from 'lucide-svelte'
  import CloudAlert from '@/components/icons/CloudAlert.svelte'
  import { status } from '@/modules/networking.js'
  import { SUPPORTS } from '@/modules/support.js'
  import { onDestroy } from 'svelte'

  let transition = true
  $: {
    const root = document.documentElement
    if ($status.match(/offline/i)) root.style.setProperty('--wrapper-offset', 'calc(var(--statusbar-height) + var(--safe-area-top))')
    else root.style.removeProperty('--wrapper-offset')
  }

  function onOrientation() {
    if ($status.match(/offline/i)) {
      transition = false
      requestAnimationFrame(() => transition = true)
    }
  }

  if (SUPPORTS.isAndroid) {
    screen.orientation.addEventListener('change', onOrientation)
    onDestroy(() => screen.orientation.removeEventListener('change', onOrientation))
  }

  // the offset lives on <html>, outside this component's teardown
  onDestroy(() => document.documentElement.style.removeProperty('--wrapper-offset'))
</script>

<div class='overflow-hidden status-bar h-0' class:status-bar-transition={transition} class:offline={!SUPPORTS.isAndroid && $status.match(/offline/i)} class:offline-safe={SUPPORTS.isAndroid && $status.match(/offline/i)}>
  <div class='z-79 position-absolute d-flex align-items-center justify-content-center overflow-hidden status-bar h-0' style='width: calc(100% - var(--safe-area-navigation-right) - var(--safe-area-left))' class:status-bar-transition={transition} class:offline={!SUPPORTS.isAndroid && $status.match(/offline/i)} class:offline-safe={SUPPORTS.isAndroid && $status.match(/offline/i)} class:padding-safe={SUPPORTS.isAndroid} class:bg-very-dark={$status.match(/offline/i)} class:bg-success={!$status.match(/offline/i)}>
    {#if $status === 'online'}
      <Earth size='1.8rem' strokeWidth='2.5' />
      <span class='ml-10 font-weight-semi-bold font-size-16'>Connection Restored</span>
    {:else if $status.match(/offline/i)}
      <svelte:component this={$status === 'offline' ? WifiOff : CloudAlert} size='1.8rem' strokeWidth='2.5' />
      <span class='ml-10 font-weight-semi-bold font-size-16'>{$status === 'offline' ? 'Offline' : 'AniList Outage'}</span>
    {/if}
  </div>
</div>

<style>
  .status-bar.offline {
    height: var(--statusbar-height);
  }
  .status-bar.offline-safe {
    height: calc(var(--statusbar-height) + var(--safe-area-top));
  }
  .status-bar.offline-safe.padding-safe {
    padding-top: var(--safe-area-top);
  }
  .status-bar-transition {
    transition: height 0.3s ease, padding-top 0.3s ease;
    transition-delay: 2s;
  }
  .status-bar:not(.status-bar-transition) {
    transition: none !important;
  }
</style>