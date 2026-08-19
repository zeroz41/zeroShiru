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
</script>

{#if type === 'episode'}

  {#await card.data}
    <EpisodeCardSk section={variables?.section} />
  {:then data}
    {#if data}
      <EpisodeCard {data} section={variables?.section} />
    {/if}
  {/await}

{:else if type === 'full'}

  {#await card.data}
    <FullCardSk />
  {:then data}
    {#if data}
      <FullCard {data} {variables} />
    {/if}
  {/await}

{:else} <!-- type === 'small'  -->

  {#await card.data}
    <SmallCardSk {variables} />
  {:then data}
    {#if data}
      <SmallCard {data} {variables} />
    {/if}
  {/await}

{/if}
