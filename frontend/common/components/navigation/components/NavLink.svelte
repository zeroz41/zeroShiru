<script>
  import { page as _page, modal as _modal } from '@/modules/navigation.js'
  import { nowPlaying } from '@/components/MediaHandler.svelte'
  import { click as _click } from '@/modules/lib/click.js'
  import { settings } from '@/modules/settings.js'
  import { onMount } from 'svelte'

  /** @type {string} */
  export let css = ''
  /** @type {string} */
  export let text = ''
  /** @type {string | null} */
  export let page = null
  /** @type {string | null} */
  export let modal = null
  /** @type {boolean} */
  export let drawer = false
  /** @type {boolean} */
  export let sidebar = false
  /** @type {boolean} */
  export let center = sidebar
  /** @type {() => void} */
  export let click = () => {}
  /** @type {() => void} */
  export let altClick = () => {}

  /** @type {boolean} */
  let hovering = false
  /** @type {boolean} */
  let useHover = false

  /** @type {boolean} */
  $: expandableSidebar = sidebar && $settings.expandingSidebar
  /** @type {boolean} */
  $: active = (!modal ? ((!$_modal || !_modal.length) && $_page === page) : modal === _modal.focused && (modal !== _modal.ANIME_DETAILS || ($_modal[_modal.ANIME_DETAILS]?.data?.id === $nowPlaying?.media?.id))) || $$restProps.class?.match('active')

  onMount(() => useHover = window.matchMedia('(hover: hover) and (pointer: fine)').matches)
</script>

<div
    class='{$$restProps.class} d-flex flex-column align-items-center flex-shrink-0 navbar-button'
    class:mx-auto={!drawer && !sidebar}
    class:w-full={drawer || expandableSidebar}
    class:sidebar-center={!drawer && sidebar && center}>
  <div
      role='button'
      tabindex='0'
      class='nav-link nav-link-with-icon pointer flex-shrink-0 h-auto align-items-center rounded {css}'
      class:d-flex={drawer || expandableSidebar}
      class:my-5={drawer}
      class:drawer={drawer}
      class:flex-row-reverse={drawer}
      class:p-10={drawer && !$settings.showLabels}
      class:pb-0={!drawer && $settings.showLabels && !expandableSidebar}
      class:w-full={drawer || (expandableSidebar && center)}
      title={text}
      on:mouseenter={() => { if (useHover) hovering = true }}
      on:mouseleave={() => { if (useHover) hovering = false }}
      on:focus={(e) => { if (useHover && e.relatedTarget != null) hovering = true }}
      on:blur={() => { hovering = false }}
      on:pointerdown={() => { if (!useHover) hovering = false }}
      use:_click={click}
      on:contextmenu|preventDefault={altClick}>
    <span class='rounded d-flex {css}' class:inactive={!active}>
      <slot {active} {hovering}/>
    </span>
    {#if text && ((drawer && $settings.showLabels) || expandableSidebar)}
      <span class='nav-link-text d-block font-size-14 text-nowrap text-right' class:ml-20={!drawer && expandableSidebar} class:active={active}>{text}</span>
    {/if}
  </div>
  {#if text && !drawer && !expandableSidebar && $settings.showLabels}
    <span class='nav-link-text d-block font-size-12 text-nowrap' class:active={active}>{text}</span>
  {/if}
</div>

<style>
  .nav-link > span:not(.nav-link-text) {
    color: var(--highlight-color);
  }
  /* the page you are ON is the one place the accent fills in: an active pill in the
     theme's own color, unmistakable at a glance from across the room */
  .nav-link:not(.drawer) > span:not(.nav-link-text):not(.inactive) {
    background: hsla(var(--tertiary-color-hsl), 0.18);
    color: var(--tertiary-color-very-light);
    box-shadow: inset 0 0 0 0.1rem hsla(var(--tertiary-color-hsl), 0.25);
  }
  /* a soft wash, not a solid white chip: the old hover swapped every nav icon to
     white-on-dark-inverted, the single most 2019-looking interaction in the app.
     The icon stays bright; the surface answers. */
  .nav-link:not(.drawer):active > span:not(.nav-link-text),
  .nav-link.drawer:active{
    background: hsla(var(--white-color-hsl), 0.16);
    color: var(--highlight-color);
  }
  .nav-link-text {
    color: var(--gray-color-very-dim);
  }
  .nav-link-text.active {
    color: var(--highlight-color);
  }
  @media (hover: hover) and (pointer: fine) {
    .nav-link:hover:not(.drawer) > span:not(.nav-link-text),
    .nav-link.drawer:hover {
      background: hsla(var(--white-color-hsl), 0.1);
      color: var(--highlight-color);
    }
  }
  /* keyboard focus keeps the global ring (it was suppressed here, leaving hover and
     focus indistinguishable) plus the same wash the pointer gets */
  .nav-link:focus-visible:not(.drawer) > span:not(.nav-link-text),
  .nav-link.drawer:focus-visible {
    background: hsla(var(--white-color-hsl), 0.1);
    color: var(--highlight-color);
  }
  .inactive {
    color: var(--gray-color-very-dim) !important;
  }

  .nav-link {
    font-size: 1.4rem;
    padding: .75rem;
    height: 5.5rem;
  }
  .nav-link.drawer {
    gap: 1.2rem;
    padding: 1rem;
  }
  .nav-link.drawer,
  .nav-link > span,
  .nav-link-text {
    /* fast enough to feel like the button answered the pointer; .8s here read as lag */
    transition: background var(--motion-quick) var(--ease-settle), color var(--motion-quick) var(--ease-settle), opacity var(--motion-quick) var(--ease-settle) !important;
  }
  .nav-link > span:not(.nav-link-text) {
    transition: background var(--motion-quick) var(--ease-settle), color var(--motion-quick) var(--ease-settle), scale var(--motion-quick) var(--ease-settle) !important;
  }
  /* the icon swells to meet the pointer and dips under a press: the whole of what makes a
     menu button feel like it answered rather than merely changed colour */
  @media (hover: hover) and (pointer: fine) {
    .nav-link:hover > span:not(.nav-link-text) {
      scale: 1.08;
    }
  }
  .nav-link:active > span:not(.nav-link-text) {
    scale: .92;
    transition: scale var(--motion-press) var(--ease-press) !important;
  }

  .sidebar-center {
    margin-left: calc((var(--sidebar-width) - 2.4rem - var(--nav-button-size)) / 2);
  }
</style>