<script>
  export let section = false
</script>

<div class='d-flex p-20 pb-10 position-relative wrapper content-visibility-auto' class:mb-100={section}>
  <div class='item load-in d-flex flex-column h-full'>
    <div class='image h-200 w-full rounded skeloader bg-ske'/>
    <div class='row pt-20'>
      <div class='col-7 d-flex flex-column'>
        <div class='h-15 skeloader w-220 bg-ske mb-8 rounded'/>
        <div class='h-10 skeloader w-180 bg-ske rounded'/>
      </div>
      <div class='col-5 d-flex flex-column align-items-end'>
        <div class='h-15 skeloader w-100 bg-ske mb-8 rounded'/>
        <div class='h-10 skeloader w-50 bg-ske rounded'/>
      </div>
    </div>
  </div>
</div>

<style>
  .item {
    width: 36rem;
    max-width: 100%;
    margin: 0 auto;
  }
  .wrapper {
    height: 28.7rem;
    contain-intrinsic-height: 28.7rem;
  }
  .mb-100 {
    margin-bottom: 10rem !important;
  }
</style>
