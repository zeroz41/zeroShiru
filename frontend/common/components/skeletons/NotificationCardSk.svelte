<script>
  /** @type {number} */
  export let index = -1
</script>

<div class='notification-item shadow-lg position-relative d-flex align-items-center mx-20 my-5 p-5 bg-dark' class:mt-15={index === 0}>
  <div class='rounded-5 d-flex justify-content-center align-items-center overflow-hidden mr-10 notification-icon-container'>
    <div class='skeloader bg-ske w-full mw-0 mw-full h-full rounded-5'/>
  </div>
  <div class='notification-content w-full mw-0 position-relative'>
    <div class='position-absolute top-0 right-0 skeloader bg-ske rounded h-30 w-30 flex-shrink-0'/>
    <div class='skeloader bg-ske h-15 rounded mt-10 w-400 mw-0' style='max-width: calc(100% - 4rem)'/>
    <div class='skeloader bg-ske h-10 rounded mt-11 w-500 mw-0 mw-full'/>
    <div class='skeloader bg-ske h-10 rounded w-500 mw-0 mw-full second-line'/>
    <div class='d-flex justify-content-between align-items-center mt-10'>
      <div class='skeloader bg-ske h-10 rounded w-80'/>
      <div class='d-flex gap-10'>
        <div class='skeloader bg-ske h-21 rounded w-80'/>
        <div class='skeloader bg-ske h-21 rounded w-40'/>
      </div>
    </div>
  </div>
</div>

<style>
  .notification-item {
    border-radius: .75rem;
  }
  .notification-icon-container {
    width: 5.5rem;
    height: 8rem;
    flex-shrink: 0;
  }
  .mt-11 {
    margin-top: 1.1rem;
  }
  .h-21 {
    height: 2.1rem;
  }
  .second-line {
    display: none;
  }
  @media (max-width: 470px) {
    .second-line {
      display: block;
      margin-top: .8rem;
    }
  }
</style>