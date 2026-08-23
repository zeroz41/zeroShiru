<script>
  // The live health surface: what the host knows about itself, refreshed while this
  // panel is on screen and costing nothing when it is not. Every debugging session
  // on this app used to start by discovering that the explaining state — a debrid
  // service gone quiet, a rate-limit pause, an art cache refusing a URL — existed
  // in memory and was visible nowhere.
  import { onDestroy } from 'svelte'
  import { DIAGNOSTICS } from '@/modules/bridge.js'
  import { fastPrettyBytes } from '@/modules/util.js'
  import { prettyDuration, serviceVerdict, lineAllowanceNotice } from '@/modules/lib/introspection.js'

  let snapshot = null
  let unsupported = false

  async function refresh () {
    try {
      const next = await DIAGNOSTICS.snapshot()
      if (next) {
        snapshot = next
        unsupported = false
      } else {
        unsupported = true
      }
    } catch {
      unsupported = true
    }
  }
  refresh()
  const timer = setInterval(refresh, 2_000)
  onDestroy(() => clearInterval(timer))

  $: allowance = lineAllowanceNotice(snapshot?.log)
</script>

<div class='bg-dark-light rounded px-20 py-15 mb-15 wm-1200 w-full'>
  <div class='d-flex align-items-center mb-10'>
    <div class='font-size-16 font-weight-semi-bold'>Live Diagnostics</div>
    {#if snapshot}
      <div class='ml-auto text-muted font-size-12'>up {prettyDuration(snapshot.uptime_ms)} · v{snapshot.version}</div>
    {/if}
  </div>
  {#if unsupported}
    <div class='text-muted'>This host does not report diagnostics.</div>
  {:else if !snapshot}
    <div class='text-muted'>Reading…</div>
  {:else}
    {#if snapshot.debrid?.length}
      {#each snapshot.debrid as service (service.service)}
        {@const verdict = serviceVerdict(service)}
        <div class='row-line d-flex align-items-center flex-wrap'>
          <span class='name text-capitalize'>{service.service}</span>
          <span class='badge tone-{verdict.tone}'>{verdict.label}</span>
          <span class='text-muted detail'>round trip ~{service.latency_ms || '—'}ms</span>
          <span class='text-muted detail'>{service.remembered_answers} answers held</span>
          {#if service.requests_in_flight || service.requests_waiting}
            <span class='text-muted detail'>{service.requests_in_flight} in flight{service.requests_waiting ? `, ${service.requests_waiting} queued` : ''}</span>
          {/if}
        </div>
      {/each}
    {:else}
      <div class='row-line text-muted'>No debrid service has been used this session.</div>
    {/if}
    <div class='row-line d-flex align-items-center flex-wrap'>
      <span class='name'>Art cache</span>
      <span class='text-muted detail'>{snapshot.media_cache.entries} images · {fastPrettyBytes(snapshot.media_cache.size_bytes)} of {fastPrettyBytes(snapshot.media_cache.cap_bytes)}</span>
      {#if snapshot.media_cache.in_flight}<span class='text-muted detail'>{snapshot.media_cache.in_flight} fetching</span>{/if}
      {#if snapshot.media_cache.recent_failures}<span class='badge tone-warning'>{snapshot.media_cache.recent_failures} dead URL{snapshot.media_cache.recent_failures === 1 ? '' : 's'}</span>{/if}
    </div>
    <div class='row-line d-flex align-items-center flex-wrap'>
      <span class='name'>Log</span>
      <span class='text-muted detail select-all'>{snapshot.log.path || 'not running'}</span>
      <span class='text-muted detail'>{fastPrettyBytes(snapshot.log.size_bytes)}</span>
    </div>
    {#if allowance}
      <div class='row-line'><span class='badge tone-warning'>{allowance}</span></div>
    {/if}
  {/if}
</div>

<style>
  .row-line {
    padding: 0.5rem 0;
    gap: 1.2rem;
  }
  .row-line + .row-line {
    border-top: 0.1rem solid hsla(var(--white-color-hsl), 0.06);
  }
  .name {
    font-weight: 600;
    min-width: 9rem;
  }
  .detail {
    font-size: 1.2rem;
  }
  .select-all {
    user-select: all;
  }
  .badge {
    border: none;
    font-size: 1.1rem;
    padding: 0.2rem 0.9rem;
    border-radius: 5rem;
  }
  .tone-ok {
    background: hsla(120, 40%, 45%, 0.18);
    color: hsl(120, 45%, 70%);
  }
  .tone-warning {
    background: hsla(45, 80%, 50%, 0.16);
    color: hsl(45, 90%, 70%);
  }
  .tone-danger {
    background: hsla(0, 70%, 55%, 0.18);
    color: hsl(0, 85%, 74%);
  }
</style>
