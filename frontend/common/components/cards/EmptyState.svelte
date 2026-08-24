<script>
  /** A calm empty state: a quiet glyph, a plain fact, and a next step. Not an alarm. */
  export let icon = null
  export let title = 'Nothing here'
  export let hint = ''
</script>

<div class='empty-state d-flex flex-column align-items-center justify-content-center text-center px-20 {$$restProps.class ?? ''}'>
  {#if icon}
    <div class='d-flex justify-content-center mb-15 state-glyph'>
      <svelte:component this={icon} size='4.8rem' strokeWidth='1.5' />
    </div>
  {/if}
  <div class='font-weight-bold font-scale-18 mb-5 text-white'>{title}</div>
  {#if hint}
    <div class='text-muted wm-600'>{hint}</div>
  {/if}
  {#if $$slots.default}
    <div class='mt-15 d-flex justify-content-center'>
      <slot />
    </div>
  {/if}
</div>

<style>
  .empty-state {
    min-height: 24rem;
    gap: .2rem;
  }
  .state-glyph {
    color: hsla(var(--white-color-hsl), 0.28);
  }
</style>
