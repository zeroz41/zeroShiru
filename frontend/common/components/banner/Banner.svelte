<script>
  import FullBanner from '@/components/banner/FullBanner.svelte'
  import BannerSk from '@/components/skeletons/BannerSk.svelte'
  import ErrorCard from '@/components/cards/ErrorCard.svelte'
  import { bannerList } from '@/modules/banner.js'
  import { settings } from '@/modules/settings.js'
  export let data

  const coverFallback = () => settings.value.adult === 'hentai' && settings.value.hentaiBanner
</script>

<div class='w-full h-400 position-relative'>
  {#await data}
    <BannerSk />
  {:then res}
    {#if res?.errors}
      <ErrorCard promise={res} />
    {:else}
      {@const mediaList = bannerList(res?.data?.Page?.media, { coverFallback: coverFallback() })}
      <!-- an offline start resolves to no media at all; the banner has nothing to rotate through -->
      {#if mediaList.length}
        <FullBanner {mediaList} />
      {:else}
        <BannerSk />
      {/if}
    {/if}
  {/await}
</div>