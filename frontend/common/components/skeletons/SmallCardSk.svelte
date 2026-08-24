<script>
  export let variables = null
  let _variables = variables
</script>
<div class='d-flex px-md-20 px-sm-10 px-5 py-20 p-15 wrapper content-visibility-auto'>
  <div class='item load-in d-flex flex-column h-full small-card'>
    {#if _variables?.scheduleList}
      <div class='d-flex flex-column align-items-center w-full pb-13'>
        <div class='skeloader rounded bg-ske h-15 w-100 mt-5'/>
        <div class='skeloader rounded bg-ske h-15 w-100 mt-5'/>
      </div>
    {/if}
    <div class='img w-full rounded skeloader bg-ske'/>
    <div class='skeloader rounded bg-ske h-10 w-150 mt-15'/>
    <div class='skeloader rounded bg-ske h-10 w-100 mt-15'/>
  </div>
</div>

<style>
  .img {
    width: 100%;
    aspect-ratio: 230/331;
  }
  .item {
    width: 100%;
    aspect-ratio: 152/296;
    /* the exact chrome SmallCard's .item wears, so a card doesn't change geometry
       the moment its data resolves */
    box-sizing: border-box;
    padding: .65rem;
    border: .1rem solid var(--surface-border);
    border-radius: 1.25rem;
    background: linear-gradient(165deg, var(--surface-panel), hsla(var(--dark-color-hsl), .72));
    box-shadow: 0 .8rem 2rem hsla(var(--black-color-hsl), .22);
  }
</style>
