<script>
  import FullBanner from '@/components/banner/FullBanner.svelte'
  import BannerSk from '@/components/skeletons/BannerSk.svelte'
  import ErrorCard from '@/components/cards/ErrorCard.svelte'
  import { bannerList } from '@/modules/banner.js'
  import { settings } from '@/modules/settings.js'
  export let data

  const coverFallback = () => settings.value.adult === 'hentai' && settings.value.hentaiBanner

  /** The hero's rotation, held as a value: an {#await data} here dropped back to the
   * skeleton every time the refresh handed over a new promise, blanking a banner that
   * was already painted. The list on screen stays until a new one actually resolves. */
  let mediaList = null
  let failure = null
  let generation = 0
  $: consume(data)
  async function consume (data) {
    const walk = ++generation
    try {
      const res = await data
      if (walk !== generation) return
      if (res?.errors) { failure = data; return }
      // an offline start resolves to no media at all; keep whatever is showing
      const list = bannerList(res?.data?.Page?.media, { coverFallback: coverFallback() })
      if (list.length) { mediaList = list; failure = null }
    } catch {
      if (walk === generation) failure = data
    }
  }
</script>

<div class='w-full h-400 position-relative'>
  {#if mediaList?.length}
    <FullBanner {mediaList} />
  {:else if failure}
    <ErrorCard promise={failure} />
  {:else}
    <BannerSk />
  {/if}
</div>