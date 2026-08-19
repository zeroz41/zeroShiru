<script>
  import HomeSection from '@/routes/home/components/HomeSection.svelte'
  import Banner from '@/components/banner/Banner.svelte'
  import { anilistClient, currentSeason, currentYear } from '@/modules/providers/anilist/anilist.js'
  import { settings } from '@/modules/settings.js'
  import { manager as _manager } from '@/modules/sections.js'
  import { writable } from 'simple-store-svelte'

  const manager = _manager

  const bannerData = writable(getTitles())
  // Refresh banner every 15 minutes
  setInterval(() => getTitles(true), 5 * 60 * 1_000)

  async function getTitles(refresh) {
    const res = anilistClient.search({ method: 'Search', ...(settings.value.adult === 'hentai' && settings.value.hentaiBanner ? { genre: ['Hentai'] } : {}), sort: 'TRENDING_DESC', perPage: 50, onList: false, ...(settings.value.adult !== 'hentai' || !settings.value.hentaiBanner ? { season: currentSeason } : {}), year: currentYear, status_not: 'NOT_YET_RELEASED' })
    if (refresh) {
      const renderData = await res
      bannerData.set(Promise.resolve(renderData))
    }
    else return res
  }

  const isPreviousRSS = (i) => {
    let index = i - 1
    while (index >= 0) {
      if (!manager.sections[index]?.hide) return manager.sections[index]?.isRSS ?? false
      else if ((index - 1 >= 0) && manager.sections[index - 1]?.isRSS) return true
      index--
    }
    return false
  }
</script>

<div class='h-full w-full overflow-y-scroll root overflow-x-hidden'>
  <Banner data={$bannerData} />
  <div class='d-flex flex-column h-full w-full mt-15'>
    {#each manager.sections as section, i (i)}
      {#if !section.hide}
        <HomeSection bind:opts={section} index={i} lastEpisode={isPreviousRSS(i)}/>
      {/if}
    {/each}
  </div>
</div>