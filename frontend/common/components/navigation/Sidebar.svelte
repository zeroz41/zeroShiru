<script>
  import { goBack, goForward, canGoBack, canGoForward } from '@/modules/navigation.js'
  import NavItem from '@/components/navigation/components/NavItem.svelte'
  import NavLink from '@/components/navigation/components/NavLink.svelte'
  import NavBar from '@/components/navigation/components/NavBar.svelte'
  import { page, drawerOpen } from '@/modules/navigation.js'
  import { DESKTOP, COMMON } from '@/modules/bridge.js'
  import { fadeIn, fadeOut } from '@/modules/util.js'
  import { MoveLeft, MoveRight } from 'lucide-svelte'
  import { settings } from '@/modules/settings.js'
  import { status } from '@/modules/networking.js'
  import { click } from '@/modules/lib/click.js'
  import { writable } from 'simple-store-svelte'

  /** @type {import('simple-store-svelte').Writable<string[]>} */
  const drawerItems = writable([])

  /**
   * Previous network status value used to detect changes
   *
   * @type {string}
   */
  let _status = status.value
  /**
   * Whether a status transition animation is active
   *
   * @type {boolean}
   */
  $: statusTransition = false
  $: {
    if (_status !== $status) {
      statusTransition = true
      setTimeout(() => (statusTransition = false), 3000)
      _status = $status
    }
  }

  /** @type {boolean} */
  let fullScreen = false
  DESKTOP.isFullScreen().then(isFullScreen => {
    fullScreen = isFullScreen
    DESKTOP.onFullScreen((isFullScreen) => fullScreen = isFullScreen)
  })

  /** Closes the overflow drawer */
  function closeDrawer() {
    drawerOpen.set(false)
  }
</script>

<div class='sidebar z-80 d-md-block' style='height: calc(100% - var(--safe-area-bottom)) !important' class:animated={$settings.expandingSidebar} class:open={$drawerOpen && $settings.expandingSidebar}>
  <div class='sidebar-base z--1 pointer-events-none h-full position-absolute' style='width: var(--sidebar-width)'/>
  <div class='sidebar-overlay z--1 pointer-events-none h-full position-absolute' class:animated={$settings.expandingSidebar} />
  <div class='sidebar-menu h-full d-flex flex-column m-0 pb-5 animate' class:br-10={!$settings.expandingSidebar}>
    <div class='w-50 top-0 flex-shrink-0 pointer-events-none {_status?.match(/offline/i) ? `h-25` : `${COMMON.getPlatformInfo().platform === `darwin` && !fullScreen ? `h-25` : `h-0`}`}' class:status-transition={statusTransition}/>
    <div class='d-flex justify-content-center z-102' style='width: var(--sidebar-width); margin-top: 1rem !important'>
      <NavLink sidebar={true} center={false} click={goBack} class={`h-auto w-30 ${$canGoBack ? 'active' : ''}`} css='rounded-left-block p-0 m-0'>
        <MoveLeft size={'2.5rem'} class='flex-shrink-0 rounded m-0' strokeWidth='2.5' />
      </NavLink>
      <NavLink sidebar={true} center={false} click={goForward} class={`h-auto w-30 ${$canGoForward ? 'active' : ''}`} css='rounded-right-block p-0 m-0'>
        <MoveRight size={'2.5rem'} class='flex-shrink-0 rounded m-0' strokeWidth='2.5' />
      </NavLink>
    </div>
    <div class='d-flex flex-column align-items-center' style='width: var(--sidebar-width)'>
      <img src='./icon_filled.png' tabindex='-1' class='brand-mark w-50 h-50 m-10 pointer d-sm-h-none p-5' alt='zeroShiru home' use:click={() => page.navigateTo(page.HOME)} />
    </div>
    <NavBar sidebar={true} {closeDrawer} bind:drawerOpen={$drawerOpen} bind:drawerItems={$drawerItems} class='align-items-start flex-column' />
  </div>
</div>

{#if $drawerOpen}<div class='drawer-backdrop position-fixed inset-0 z-100 pointer-events-none d-none d-md-block' class:z-79={!$settings.expandingSidebar} in:fadeIn={{ y: 0, startScale: 1, duration: 200 }} out:fadeOut={{ y: 0, endScale: 1, duration: 150 }} />{/if}
<div class='drawer position-fixed left-0 bottom-0 mb-navigation-safe-area z-100 bg-very-dark d-none d-md-block' class:open={$drawerOpen} class:expanding={$settings.expandingSidebar} class:z-79={!$settings.expandingSidebar} class:bt-10={!$settings.expandingSidebar} class:br-10={!$settings.expandingSidebar} role='dialog' aria-label='More'>
  <div class='drawer-handle position-absolute pointer' tabindex='-1' class:d-none={$settings.expandingSidebar} use:click={closeDrawer} on:pointerdown={closeDrawer} />
  <div class='overflow-y-auto vh-60'>
    {#each $drawerItems as item (item)}
      <NavItem {item} sidebar={true} size={'2.4rem'} drawer={true} {closeDrawer} />
    {/each}
  </div>
</div>

<style>
  .sidebar {
    background: none !important;
    overflow-y: unset;
    overflow-x: visible;
    left: unset;
  }
  .sidebar.animated, .sidebar-overlay.animated {
    transition: width var(--motion-panel) var(--ease-settle), left var(--motion-panel) var(--ease-settle) !important;
  }
  .sidebar.animated:not(.open):hover {
    width: 22rem;
  }
  .sidebar-overlay {
    width: var(--sidebar-width);
    background: linear-gradient(90deg, var(--surface-shell) 0%, hsla(var(--dark-color-hsl), .9) 42%, hsla(var(--dark-color-hsl), .5) 72%, transparent 100%);
  }
  .sidebar-base {
    background: linear-gradient(180deg, var(--surface-panel-strong), var(--surface-shell));
    border-right: .1rem solid var(--surface-border);
    box-shadow: 1.2rem 0 3rem hsla(var(--black-color-hsl), .32);
  }
  .brand-mark {
    border-radius: 1.35rem;
    background: linear-gradient(145deg, hsla(var(--tertiary-color-hsl), .3), var(--surface-highlight));
    box-shadow: inset 0 0 0 .1rem hsla(var(--white-color-hsl), .15), 0 .8rem 2rem hsla(var(--black-color-hsl), .42);
  }
  .sidebar.animated:hover .sidebar-overlay,
  .sidebar.animated.open .sidebar-overlay {
    width: 63rem
  }

  .drawer {
    border-radius: 0 1rem 0 0;
    transform: translateX(-200%);
    transition: transform .38s cubic-bezier(.32, .72, 0, 1);
    padding: .5rem 3rem .5rem calc(var(--safe-area-left) + var(--sidebar-width) + 1rem);
  }
  .drawer.expanding {
    transform: translateY(200%);
    padding: .5rem 3rem 1rem 1rem;
    background: transparent !important;
    left: calc(var(--safe-area-left) + var(--sidebar-width)) !important;
  }
  .drawer-handle {
    width: .4rem;
    height: 3.6rem;
    border-radius: .2rem;
    right: 1rem;
    top: 50%;
    transform: translateY(-50%);
    background: var(--gray-color-very-dim);
  }
  .drawer-backdrop { background: hsla(var(--black-color-hsl), .45); }
  .drawer.expanding.open { transform: translateY(0); }
  .drawer.open { transform: translateX(0); }

  @media (min-width: 769px) {
    .sidebar::after {
      content: '';
      position: fixed;
      left: 0;
      top: 0;
      bottom: 0;
      width: var(--safe-area-left);
      background: var(--surface-shell);
    }
  }
</style>
