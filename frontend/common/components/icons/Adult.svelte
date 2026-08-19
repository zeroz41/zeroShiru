<script>
  import Icon from './Icon.svelte'
  const iconNode = [['path', { d: 'M6.5 10 L9 8' }], ['path', { d: 'M9 8 L9 16' }], ['path', { d: 'M14 2.2a10 10 0 1 0 7.8 7.8' }], ['path', { d: 'M18 4h4' }], ['path', { d: 'M20 6V2' }], ['circle', { cx: '15', cy: '10', r: '2' }], ['circle', { cx: '15', cy: '14', r: '2' }]]
</script>

<Icon name='adult' {...$$props} {iconNode}>
  <slot />
</Icon>
