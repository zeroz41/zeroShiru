<script>
  import HomeSection from '@/routes/home/components/HomeSection.svelte'
  import Banner from '@/components/banner/Banner.svelte'
  import { anilistClient, currentSeason, currentYear } from '@/modules/providers/anilist/anilist.js'
  import { settings } from '@/modules/settings.js'
  import { manager as _manager } from '@/modules/sections.js'
  import { writable } from 'simple-store-svelte'
  import { onDestroy } from 'svelte'

  const manager = _manager

  const bannerData = writable(getTitles())
  /** Which titles the hero is rotating through. The refresh below used to replace the
   * banner promise unconditionally: every five minutes the hero re-entered its skeleton
   * and re-shuffled to an unrelated show, over data that had not changed. Same ids in
   * the same order means there is nothing to repaint. */
  let bannerIds = ''
  const idsOf = res => res?.data?.Page?.media?.map(media => media?.id).join(',') ?? ''
  Promise.resolve(bannerData.value).then(res => { bannerIds = idsOf(res) }).catch(() => {})
  // one interval per mount, cleared on destroy — this used to stack a new five-minute
  // timer on every visit to Home, forever
  const bannerRefresh = setInterval(() => getTitles(true), 5 * 60 * 1_000)
  onDestroy(() => clearInterval(bannerRefresh))

  async function getTitles(refresh) {
    const res = anilistClient.search({ method: 'Search', ...(settings.value.adult === 'hentai' && settings.value.hentaiBanner ? { genre: ['Hentai'] } : {}), sort: 'TRENDING_DESC', perPage: 50, onList: false, ...(settings.value.adult !== 'hentai' || !settings.value.hentaiBanner ? { season: currentSeason } : {}), year: currentYear, status_not: 'NOT_YET_RELEASED' })
    if (!refresh) return res
    try {
      const renderData = await res
      const ids = idsOf(renderData)
      if (ids && ids !== bannerIds) {
        bannerIds = ids
        bannerData.set(Promise.resolve(renderData))
      }
    } catch { /* a failed refresh keeps the banner it has */ }
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

<div class='home-page h-full w-full overflow-y-scroll root overflow-x-hidden'>
  <Banner data={$bannerData} />
  <div class='home-feed d-flex flex-column h-full w-full mt-15'>
    {#each manager.sections as section, i (i)}
      {#if !section.hide}
        <HomeSection bind:opts={section} index={i} lastEpisode={isPreviousRSS(i)}/>
      {/if}
    {/each}
  </div>
</div>

<style>
  .home-page { background: transparent; }
  .home-feed {
    position: relative;
    padding-top: 2.4rem;
    border-top: .1rem solid var(--surface-border);
    border-radius: 2.4rem 2.4rem 0 0;
    background: linear-gradient(180deg, var(--surface-highlight), transparent 28rem);
    box-shadow: 0 -1.2rem 3rem hsla(var(--black-color-hsl), .18);
  }
</style>
