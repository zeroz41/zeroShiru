<script>
  export let images = []
  export let hidden = false
  export let style = null
  export let color = null
  export let title = ''

  let index = 0
  let resolvedImages = []
  let failed = false
  let loading = false
  $: if (images) { index = 0; resolvedImages = []; failed = false; }
  $: filteredImages = images.filter(Boolean)
  $: loadNextImage(index, filteredImages)
  async function loadNextImage(index, filteredImages) {
    let image = filteredImages[index]
    loading = true
    try {
      if (typeof image === 'function') image = image()
      if (image && typeof image.then === 'function') image = await image
      if (Array.isArray(image)) {
        filteredImages.splice(index, 1, ...image.filter(Boolean))
        image = filteredImages[index]
      }
    } catch { image = `${index}_404.jpg` }
    if (typeof image === 'string' && image.includes('/cover/') && image.endsWith('/default.jpg')) image = 'no_image_cover.jpg'
    resolvedImages[index] = image
    loading = false
  }
  function handleError() {
    if (loading) return
    if (index < filteredImages.filter(Boolean).length - 1) index += 1
    else failed = true
  }
  function validate(event) {
    const image = event.target
    if (/ytimg\.com|youtube\.com|youtube-nocookie\.com|youtu\.be/i.test(image.currentSrc || image.src) && image.naturalWidth === 120 && image.naturalHeight === 90) handleError()
  }
</script>
<img
    class={($$restProps.class ? $$restProps.class.split(' ').filter(_class => (_class !== 'cover-rotated' && _class !== 'cr-380' && _class !== 'cr-400') || !resolvedImages[index]?.includes('404')).join(' ') : '') + (color ? ' cover-color' : '')}
    style={(color ? `--color: ${color};` : '') + (style ? `${style}` : '')}
    class:d-none={hidden || failed}
    on:error={handleError}
    on:load={validate}
    alt='preview'
    title={title}
    draggable='false'
    loading='lazy'
    referrerpolicy='no-referrer'
    src={(!hidden && !failed) ? (loading ? 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7' : resolvedImages[index] || `${index}_404.jpg`) : ''}
/>