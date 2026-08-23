<script>
  import { nearViewport } from '@/modules/preload.js'
  import { COMMON } from '@/modules/bridge.js'
  import { rememberShown, wasShown, imageSignature } from '@/modules/lib/image-memory.js'
  import { pin, isHeld } from '@/modules/lib/image-store.js'

  export let images = []
  /** What the art is OF (a media id), for lists with function candidates — a fresh
   * closure per render carries no identity of its own. */
  export let identity = null
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
  /** The real source behind each resolved entry: what loads may be a blob: URL, and a
   * blob means nothing to the shown-memory — identity belongs to the source. */
  let sourceImages = []
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
  let signature = imageSignature(images, identity)
  /** The working candidate list. Component state rather than a derived value on purpose:
   * a candidate that expands into several URLs splices itself in here, and a derived
   * array would silently recompute and throw that expansion away mid-walk. */
  let candidates = usable(images)
  /** Stamps each load walk; a walk that awaited across a reset must not write its
   * answers into the art of whatever this card shows now. */
  let generation = 0
  $: reset(images, identity)
  $: loadNextImage(index, candidates)
  function usable (images) {
    // a whitespace-only "url" survives filter(Boolean) and the HTML parser trims it to
    // empty, which requests the app's own document — one phantom request per artless card
    return (images ?? []).filter(image => image && (typeof image !== 'string' || image.trim()))
  }
  function reset (images, identity) {
    const next = imageSignature(images, identity)
    if (next === signature) return
    signature = next
    generation++
    candidates = usable(images)
    index = 0
    resolvedImages = []
    sourceImages = []
    failed = false
  }
  async function loadNextImage(index, candidates) {
    // nothing to try is a plain miss: without this the element asked the host for a
    // literal "0_404.jpg", a file that has never existed, on every render with no art
    if (!candidates.length) { failed = true; return }
    const walk = generation
    let image = candidates[index]
    loading = true
    try {
      if (typeof image === 'function') image = image()
      if (image && typeof image.then === 'function') image = await image
      if (walk !== generation) return // the card shows something else now
      if (Array.isArray(image)) {
        candidates.splice(index, 1, ...image.filter(Boolean))
        image = candidates[index]
      }
    } catch { image = null }
    if (walk !== generation) return
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
    const source = COMMON.mediaSrc(image)
    sourceImages[index] = source
    // bytes the store already holds are free to show right now: no gate, no fade.
    // Everything else loads from its URL first and is pinned AFTER it proves itself
    // (see handleLoad) — pinning before the first paint would put a fetch ahead of it
    if (isHeld(source)) {
      resolvedImages[index] = await pin(source)
      if (walk !== generation) return
      near = true
      ready = true
      reveal = false
    } else {
      resolvedImages[index] = source
      if (wasShown(source)) {
        reveal = false
      } else if (!eager) {
        reveal = true
      }
    }
    loading = false
  }
  /** Moves to the next candidate, or gives up when this was the last one. Writing `index`
   * re-runs the loader reactively. */
  function advance(from) {
    if (from < candidates.length - 1) index = from + 1
    else failed = true
  }
  function handleError() {
    if (loading) return
    // a pinned blob that was evicted and re-rendered dies here; the source URL is
    // still good, so fall back to it rather than skipping the candidate
    if (resolvedImages[index]?.startsWith('blob:') && sourceImages[index]) {
      resolvedImages[index] = sourceImages[index]
      return
    }
    advance(index)
  }
  async function handleLoad(event) {
    validate(event)
    if (failed || hidden) return
    const src = event.target?.currentSrc || event.target?.src || ''
    if (src.startsWith('data:')) return // the placeholder pixel is not an arrival
    ready = true
    // remembered by SOURCE identity — what actually loaded may be a blob: URL that
    // means nothing next session — and pinned now that the URL proved it serves an
    // image, so scrolling away and back re-paints from memory instead of reloading
    const source = sourceImages[index] || src
    rememberShown(source)
    if (!src.startsWith('blob:')) {
      const walk = generation
      const object = await pin(source)
      if (walk === generation && object !== source) resolvedImages[index] = object
    }
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