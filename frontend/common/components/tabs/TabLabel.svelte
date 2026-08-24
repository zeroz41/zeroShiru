<script>
  import { getContext } from 'svelte'
  import { TABS } from '@/components/tabs/Tabs.svelte'
  import { click } from '@/modules/lib/click.js'

  const tab = {}
  export let name = ''
  export let action = null
  export let sidebar = false
  export let substitute = false
  const { registerTab, selectTab, selectedTab } = getContext(TABS)

  registerTab(tab)
</script>

<div class='tab-label pointer mx-auto pl-lg-20 w-lg-full {sidebar ? `d-none d-lg-block` : ``} {substitute ? `d-sm-h-block d-sm-none` : ``}' class:active={$selectedTab === tab} title={name} use:click={() => (action ?? (() => selectTab(tab)))()}>
  <span class='d-flex align-items-center rounded'>
    <slot active={$selectedTab === tab}/>
  </span>
</div>

<style>
  .tab-label > span {
    color: var(--highlight-color);
    border-radius: 0.3rem;
  }
  .tab-label > span {
    color: var(--highlight-color);
    transition: background var(--motion) var(--ease-settle), color var(--motion) var(--ease-settle);
  }
  .tab-label.active > span {
    background: linear-gradient(90deg, hsla(var(--tertiary-color-hsl), .38), hsla(var(--tertiary-color-hsl), .12));
    box-shadow: inset .3rem 0 0 var(--tertiary-color-light), inset 0 0 0 .1rem hsla(var(--tertiary-color-hsl), .3);
  }
  /* the same soft wash the nav uses — the solid white hover chip retired with it */
  .tab-label:active > span {
    background: hsla(var(--white-color-hsl), 0.16);
    color: var(--highlight-color);
  }
  @media (hover: hover) and (pointer: fine) {
    .tab-label:hover > span {
      background: hsla(var(--white-color-hsl), 0.1);
      color: var(--highlight-color);
    }
  }
  .tab-label:focus-visible > span {
    background: hsla(var(--white-color-hsl), 0.1);
    color: var(--highlight-color);
  }
  .tab-label {
    font-size: 1.4rem;
    padding: 0.75rem;
    height: 5.5rem;
    min-width: 0;
  }
</style>
