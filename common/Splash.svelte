<script>
  import Menubar from '@/components/Menubar.svelte'
  export let done = false
</script>

<Menubar primary={false} />
<div class='splash-container position-fixed inset-0 d-flex align-items-center justify-content-center bg-dark overflow-hidden' class:hidden={done} class:pointer-events-none={done}>
  <img src='./icon_filled.png' alt='zeroShiru' class='splash-logo' />
</div>

<style>
  .splash-container {
    transition: opacity 600ms ease 200ms, visibility 600ms ease 200ms;
  }
  .splash-logo {
    width: 18rem;
    height: 18rem;
    animation: float 3s ease-in-out infinite;
  }
  @keyframes float {
    0%, 100% { transform: translateY(0); }
    50% { transform: translateY(-1rem); }
  }
</style>