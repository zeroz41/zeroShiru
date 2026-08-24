<script>
  import SmallCardSk from '@/components/skeletons/SmallCardSk.svelte'
  import SmallCard from '@/components/cards/SmallCard.svelte'
  import EpisodeCardSk from '@/components/skeletons/EpisodeCardSk.svelte'
  import FullCard from '@/components/cards/FullCard.svelte'
  import EpisodeCard from '@/components/cards/EpisodeCard.svelte'
  import FullCardSk from '@/components/skeletons/FullCardSk.svelte'
  import { settings } from '@/modules/settings.js'

  export let card

  export let variables = null
  const type = card.type || $settings.cards

  /** The card's media, held as a value. An {#await card.data} here re-entered its
   * pending branch every time a rail refresh handed over a new promise — even one that
   * resolves instantly from cache — so every refresh flashed a full row of skeletons
   * over art that was already painted. The last-known media stays on screen until the
   * new promise actually lands with something different; a skeleton shows only while
   * this slot has never shown anything at all. */
  let data = null
  /** The newest promise settled — distinguishes "still loading" from "loaded nothing". */
  let settled = false
  let generation = 0
  $: resolve(card)
  async function resolve (card) {
    const walk = ++generation
    try {
      const value = await card.data
      if (walk !== generation) return
      data = value ?? null
      settled = true
    } catch {
      // errors surface through the rail's ErrorCard; this slot just has nothing to show
      if (walk !== generation) return
      settled = true
    }
  }
</script>

{#if type === 'episode'}

  {#if data}
    <EpisodeCard {data} section={variables?.section} />
  {:else if !settled}
    <EpisodeCardSk section={variables?.section} />
  {/if}

{:else if type === 'full'}

  {#if data}
    <FullCard {data} {variables} />
  {:else if !settled}
    <FullCardSk />
  {/if}

{:else} <!-- type === 'small'  -->

  {#if data}
    <SmallCard {data} {variables} />
  {:else if !settled}
    <SmallCardSk {variables} />
  {/if}

{/if}
