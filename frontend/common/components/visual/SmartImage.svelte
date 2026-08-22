<script>
  import { nearViewport } from '@/modules/preload.js'
  import { COMMON } from '@/modules/bridge.js'
  import { rememberShown, wasShown, imageSignature } from '@/modules/lib/image-memory.js'

  export let images = []
  /** Skip the wait: for art that is on screen from the start, like the home banner. */
  export let eager = false
  export let hidden = false
  export let style = null
  export let color = null
  export let title = ''

  /** A transparent pixel: what the element shows while there is nothing real to show. */
  const PLACEHOLDER = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'

  let near = eager
  let index = 0
  let resolvedImages = []
  let failed = false
  let loading = false
  /** First time on screen: fade it in so its arrival is an entrance rather than a pop.
   * An image the session has already shown skips both the lazy gate and the fade. */
  let reveal = false
  let ready = eager
  /** What the current candidate list actually IS, rather than which array object it came
   * in as. Every call site builds the list inline — `images={[cover, fallback]}` — so the
   * prop is a brand new array on every render of the parent, whatever it holds. Resetting
   * on that identity threw away resolved art and re-ran the whole load for a card whose
   * picture had not changed, which is a placeholder flash per parent update. */
  let signature = imageSignature(images)
  $: reset(images)
  $: filteredImages = images.filter(Boolean)
  $: loadNextImage(index, filteredImages)
  function reset (images) {
    const next = imageSignature(images)
    if (next !== null && next === signature) return
    signature = next
    index = 0
    resolvedImages = []
    failed = false
  }
  async function loadNextImage(index, filteredImages) {
    // nothing to try is a plain miss: without this the element asked the host for a
    // literal "0_404.jpg", a file that has never existed, on every render with no art
    if (!filteredImages.length) { failed = true; return }
    let image = filteredImages[index]
    loading = true
    try {
      if (typeof image === 'function') image = image()
      if (image && typeof image.then === 'function') image = await image
      if (Array.isArray(image)) {
        filteredImages.splice(index, 1, ...image.filter(Boolean))
        image = filteredImages[index]
      }
    } catch { image = null }
    if (!image) {
      // a candidate that failed to produce a URL is skipped like one that failed to load,
      // without a round trip through a request that cannot succeed
      loading = false
      advance(index)
      return
    }
    if (typeof image === 'string' && image.includes('/cover/') && image.endsWith('/default.jpg')) image = 'no_image_cover.jpg'
    // hosts with a native media cache serve remote art from disk; local fallbacks
    // and data: URIs pass through untouched
    resolvedImages[index] = COMMON.mediaSrc(image)
    // an image this session already showed is local and warm: the lazy gate and the fade
    // would only re-play a loading story for something that is not loading. This is what
    // stops a whole grid of known art flashing placeholders on every page switch
    if (wasShown(resolvedImages[index])) {
      near = true
      ready = true
      reveal = false
    } else if (!eager) {
      reveal = true
    }
    loading = false
  }
  /** Moves to the next candidate, or gives up when this was the last one. Writing `index`
   * re-runs the loader reactively. */
  function advance(from) {
    if (from < filteredImages.filter(Boolean).length - 1) index = from + 1
    else failed = true
  }
  function handleError() {
    if (loading) return
    advance(index)
  }
  function handleLoad(event) {
    validate(event)
    if (failed || hidden) return
    const src = event.target?.currentSrc || event.target?.src || ''
    if (src.startsWith('data:')) return // the placeholder pixel is not an arrival
    ready = true
    rememberShown(src)
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
    class:img-reveal={reveal}
    class:img-ready={ready}
    use:nearViewport={{ near: () => { near = true }, skip: eager }}
    on:error={handleError}
    on:load={handleLoad}
    alt='preview'
    title={title}
    draggable='false'
    loading='eager'
    decoding='async'
    referrerpolicy='no-referrer'
    src={(!hidden && !failed) ? ((!near || (loading && !resolvedImages[index])) ? PLACEHOLDER : resolvedImages[index] || PLACEHOLDER) : ''}
/>
<style>
  /* the first time an image arrives it fades up from the colored placeholder instead of
     popping over it; a remount of art the session has shown skips this entirely */
  .img-reveal.img-ready {
    animation: image-reveal .25s ease-out;
  }
  @keyframes image-reveal {
    from { opacity: .35; }
    to { opacity: 1; }
  }
</style>