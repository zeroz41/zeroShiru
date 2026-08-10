<script>
  import { click } from '@/modules/lib/click.js'
  import { toast } from 'svelte-sonner'
  import { Eye, EyeOff } from 'lucide-svelte'
  import SettingCard from '@/routes/settings/components/SettingCard.svelte'
  import { debridOptions, testDebrid } from '@/modules/debrid/debrid.js'
  export let settings

  let showKey = false
  let testing = false
  function testConnection () {
    if (testing) return
    testing = true
    toast.promise(testDebrid().finally(() => { testing = false }), {
      loading: 'Testing debrid connection...',
      success: ({ username, expires }) => `Connected as ${username}${expires ? `, premium until ${new Date(expires).toLocaleDateString()}` : ''}.`,
      error: (error) => `Connection failed: ${error?.message || error}`
    })
  }
</script>

<h4 class='mb-10 font-weight-bold'>Debrid Settings</h4>
<SettingCard title='Debrid Service' description='Streams releases over HTTPS from a debrid service instead of peer-to-peer whenever they are available in its cache. The torrent client keeps working as usual, uncached releases simply play as torrents.'>
  <select class='form-control bg-dark w-300 mw-full' bind:value={settings.debridService}>
    <option value='none' selected>None</option>
    {#each debridOptions as service (service.id)}
      <option value={service.id}>{service.title}</option>
    {/each}
  </select>
</SettingCard>
{#if settings.debridService !== 'none'}
  <SettingCard title='API Key' description='The private API key for your debrid account. Stored locally and excluded from settings exports.'>
    <div class='input-group mw-100 w-400 flex-nowrap'>
      <input
          type={showKey ? 'text' : 'password'}
          class='form-control bg-dark mw-0 text-truncate'
          placeholder='API key'
          autocomplete='off'
          spellcheck='false'
          value={settings.debridApiKey}
          on:input={event => { settings.debridApiKey = event.target.value.trim() }}
          on:keydown|stopPropagation
      />
      <div class='input-group-append d-flex'>
        <button type='button' class='btn btn-secondary d-flex align-items-center justify-content-center' title={showKey ? 'Hide API key' : 'Show API key'} use:click={() => { showKey = !showKey }}>
          <svelte:component this={showKey ? EyeOff : Eye} size='1.8rem' />
        </button>
        <button type='button' class='btn btn-primary d-flex align-items-center justify-content-center' disabled={!settings.debridApiKey || testing} use:click={testConnection}><span class='text-truncate'>Test</span></button>
      </div>
    </div>
  </SettingCard>
  <SettingCard title='Playback Mode' description='Debrid First plays cached releases from the debrid service and quietly falls back to the torrent client for anything uncached. Debrid Only never starts torrent downloads, uncached releases show an error instead.'>
    <select class='form-control bg-dark w-300 mw-full' bind:value={settings.debridMode}>
      <option value='prefer' selected>Debrid First</option>
      <option value='only'>Debrid Only</option>
    </select>
  </SettingCard>
  <SettingCard title='Confirm Cache Status' description='Checks whether the top search results can be streamed instantly, so the Cached badge is a fact rather than a guess. Services with a cache endpoint answer for every result in one request. Real-Debrid has none, so a small number of top results are confirmed by briefly adding and removing the magnet, which never touches your own downloads. Turn this off to badge only the releases already on your account.'>
    <input type='checkbox' id='debrid-cache-check' bind:checked={settings.debridCacheCheck} />
  </SettingCard>
{/if}
