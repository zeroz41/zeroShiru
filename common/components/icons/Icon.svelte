<script>
  // Local copy of lucide-svelte's internal Icon.svelte (ISC licensed) — the
  // package's exports map doesn't expose it, and these app-owned custom icons
  // used to live inside the package via a patch (patches/lucide-svelte@*.patch).
  const defaultAttributes = {
    xmlns: 'http://www.w3.org/2000/svg',
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    'stroke-width': 2,
    'stroke-linecap': 'round',
    'stroke-linejoin': 'round'
  }
  export let name = undefined
  export let color = 'currentColor'
  export let size = 24
  export let strokeWidth = 2
  export let absoluteStrokeWidth = false
  export let iconNode = []
  const mergeClasses = (...classes) => classes.filter((className, index, array) => {
    return Boolean(className) && array.indexOf(className) === index
  }).join(' ')
</script>

<svg
  {...defaultAttributes}
  {...$$restProps}
  width={size}
  height={size}
  stroke={color}
  stroke-width={
    absoluteStrokeWidth
      ? Number(strokeWidth) * 24 / Number(size)
      : strokeWidth
  }
  class={
    mergeClasses(
      'lucide-icon',
      'lucide',
      name ? `lucide-${name}` : '',
      $$props.class
    )
  }
>
  {#each iconNode as [tag, attrs]}
    <svelte:element this={tag} {...attrs}/>
  {/each}
  <slot />
</svg>
