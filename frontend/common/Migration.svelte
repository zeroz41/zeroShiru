<script>
  import { COMMON } from '@/modules/bridge.js'
  import { migrationStatus } from '@/modules/cache.js'
  import { Database } from 'lucide-svelte'
  import { onMount } from 'svelte'
  import Menubar from '@/components/Menubar.svelte'

  export let done = false

  onMount(() => COMMON.windowReady())
</script>

<Menubar primary={false} />
<div class='migration-backdrop position-fixed inset-0 d-flex align-items-center justify-content-center bg-dark' class:hidden={done} class:pointer-events-none={done}>
  <div class='migration-card d-flex flex-column align-items-center w-full wm-1000 text-center gap-5 py-20 px-40 z-100'>
    <Database class='block-scale-160' size={192} strokeWidth={1.25} color='var(--dm-muted-text-color)' />
    <span class='font-size-34 font-weight-bold text-white mt-10'>Migrating Your Data</span>
    <span class='font-size-22 text-muted'>zeroShiru is reorganizing your cached data, this only happens once.</span>
    <div class='migration-status-row d-flex align-items-center gap-10 mb-10 mt-30'>
      <span class='migration-dot rounded-circle flex-shrink-0 bg-septenary' />
      <span class='font-size-18 text-muted mt-2'>{$migrationStatus ?? 'Preparing your data for migration...'}</span>
    </div>
    <div class='migration-bar w-full rounded-5 h-10 bg-dark-light overflow-hidden'>
      <div class='migration-bar-fill h-full rounded-5 bg-septenary' />
    </div>
    <div class='particles position-absolute inset-0 pointer-events-none overflow-hidden'>
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 15%; --delay: 0s; --duration: 3.2s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 28%; --delay: .8s; --duration: 2.8s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 42%; --delay: 1.6s; --duration: 3.5s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 57%; --delay: .3s; --duration: 2.6s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 70%; --delay: 1.2s; --duration: 3.8s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 83%; --delay: 2.1s; --duration: 3s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 22%; --delay: 2.5s; --duration: 2.9s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 65%; --delay: .6s; --duration: 3.3s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 48%; --delay: 1.9s; --duration: 2.7s;' />
      <span class='particle position-absolute rounded-circle bg-septenary' style='--x: 35%; --delay: 3s; --duration: 3.6s;' />
    </div>
  </div>
</div>

<style>
  .font-size-34 {
    font-size: 3.4rem;
  }
  .migration-backdrop {
    transition: opacity 600ms ease 200ms, visibility 600ms ease 200ms;
  }
  .migration-dot {
    width: 1.8rem;
    height: 1.8rem;
    animation: pulse 1.4s ease-in-out infinite;
  }
  .migration-bar-fill {
    animation: bar-slide 1.8s ease-in-out infinite;
    transform-origin: left;
  }
  @keyframes pulse {
    0%, 100% { opacity: 1; }
    50% { opacity: .3; }
  }
  @keyframes bar-slide {
    0%   { transform: translateX(-100%) scaleX(.4); }
    50%  { transform: translateX(60%) scaleX(.6); }
    100% { transform: translateX(200%) scaleX(.4); }
  }
  :global(.migration-card svg) {
    animation: float 3s ease-in-out infinite;
  }
  @keyframes float {
    0%, 100% { transform: translateY(0); }
    50% { transform: translateY(-1rem); }
  }
  .particle {
    bottom: 20%;
    left: var(--x);
    width: .6rem;
    height: .6rem;
    opacity: 0;
    animation: rise var(--duration) ease-in var(--delay) infinite;
  }
  @keyframes rise {
    0%   { opacity: 0; transform: translateY(0) scale(1); }
    20%  { opacity: .5; }
    80%  { opacity: .15; }
    100% { opacity: 0; transform: translateY(-60rem) scale(.3); }
  }
</style>