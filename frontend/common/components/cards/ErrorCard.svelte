<script>
  // Empty and broken are different stories: "no results" is a calm fact with a next
  // step, while "Ooops!" is an alarm. This card told both the same way for years.
  import { SearchX, CircleAlert } from 'lucide-svelte'
  export let promise
  export let containerClass = ''

  /** Whether a result's errors amount to "nothing here" rather than "something broke". */
  function isEmptiness (res) {
    if (!res?.errors) return true
    const described = JSON.stringify(res.errors) || ''
    return /found no results|will be released on|hasn't released yet/i.test(described)
  }
</script>

{#await promise then res}
  {#if !res || res?.errors}
    {@const errors = res?.errors}
    <div class='error-card p-20 d-flex align-items-center justify-content-center w-full h-387 {containerClass}'>
      <div class='{$$restProps.class}'>
        <div class='d-flex justify-content-center mb-10 state-glyph' class:calm={isEmptiness(res)}>
          {#if isEmptiness(res)}
            <SearchX size='6rem' strokeWidth='1.4' />
          {:else}
            <CircleAlert size='6rem' strokeWidth='1.4' />
          {/if}
        </div>
        <h1 class='mb-5 text-white font-weight-bold text-center'>
          {isEmptiness(res) ? 'Nothing here' : 'Something went wrong'}
        </h1>
        {#if errors}
          <div class='font-size-22 text-center text-muted'>
            {#if JSON.stringify(errors)?.match(/found no results/i) || JSON.stringify(errors)?.match(/will be released on|hasn't released yet/i)}
              No results found.
            {:else if (JSON.stringify(errors)?.match(/extension is not enabled/i) && !errors?.filter(error => !error?.message.match(/extension is not enabled/i))?.length) || JSON.stringify(errors)?.match(/sources configured/i)}
              No Extensions Installed
            {:else if JSON.stringify(errors)?.match(/changelog unavailable/i)}
              Changelog Unavailable
            {:else if errors?.length === 1 && Array.isArray(errors[0].message)}
              {errors[0].message[0]}
            {:else if errors}
              Looks like something went wrong!
            {/if}
          </div>
        {/if}
        <div class='font-size-20 text-center text-muted'>
          {#if !res?.errors}
            Looks like there's nothing here.
          {:else if JSON.stringify(errors)?.match(/extension is not enabled/i) && !errors?.filter(error => !error?.message.match(/extension is not enabled/i))?.length}
            It looks like you haven't added any extension sources, manage your extensions in the settings.
          {:else if JSON.stringify(errors)?.match(/found no results/i)}
            You can manually specify a torrent by providing a link or file.
          {:else if JSON.stringify(errors)?.match(/changelog unavailable/i)}
            The repository may be gone or access is currently being blocked or limited, but you can still update using the button below.
          {:else if errors?.length === 1 && Array.isArray(errors[0].message)}
           {#each errors[0].message.slice(1) as message}
             <div>{message}</div>
           {/each}
          {:else}
            {#each errors?.filter(error => !error.message.match(/found no results|extension is not enabled/i)) as error}
              <div>{error.message}</div>
            {/each}
          {/if}
        </div>
      </div>
    </div>
  {/if}
{:catch error}
  <div class='error-card p-20 d-flex align-items-center justify-content-center w-full h-387 {containerClass}'>
    <div class='{$$restProps.class}'>
      <div class='d-flex justify-content-center mb-10 state-glyph'>
        <CircleAlert size='6rem' strokeWidth='1.4' />
      </div>
      <h1 class='mb-5 text-white font-weight-bold text-center'>
        Something went wrong
      </h1>
      <div class='font-size-20 text-center text-muted'>
        {error.message}
      </div>
    </div>
  </div>
{/await}

<style>
  .h-387 {
    height: 38.7rem;
  }
  .state-glyph {
    color: hsla(var(--white-color-hsl), 0.35);
  }
  .state-glyph.calm {
    color: hsla(var(--white-color-hsl), 0.25);
  }
</style>