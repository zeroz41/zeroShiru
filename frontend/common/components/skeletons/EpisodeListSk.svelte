<div class='load-in rounded w-full h-full overflow-hidden d-flex flex-xsm-column flex-row pointer position-relative bg-dark'>
  <div class='h-full bg-ske'>
    <div class='skeloader bg-ske h-full w-266 overflow-hidden img-cover'/>
  </div>
  <div class='h-full w-full px-20 pt-15 d-flex flex-column'>
    <div class='w-full d-flex flex-row mb-20 mt-0 title'>
      <div class='skeloader episode-title w-full bg-ske h-25 rounded'/>
      <div class='skeloader ml-auto bg-ske w-30 h-25 rounded flex-shrink-0'/>
    </div>
    <div class='skeloader bg-ske w-full h-10 overflow-hidden rounded'/>
    <div class='skeloader description bg-ske w-full h-10 overflow-hidden rounded'/>
    <div class='skeloader n-description bg-ske w-full h-10 overflow-hidden rounded'/>
    <div class='skeloader n-description bg-ske w-full h-10 overflow-hidden rounded'/>
    <div class='skeloader bg-ske h-20 rounded mt-15 date'/>
  </div>
</div>

<style>
  .w-266 {
    width: 26.6rem !important;
  }
  .episode-title {
    max-width: 40rem !important;
    margin-right: 4rem;
  }
  .n-description {
    margin-top: 0.8rem;
  }
  .description {
    margin-top: 0.8rem;
    display: none;
  }
  .date {
    max-width: 30rem !important;
  }

  /* Behavior for narrow screens (mobile) */
  @media (max-width: 470px) {
    .flex-xsm-column {
      flex-direction: column !important;
    }
    .description {
      display: block !important;
    }
    .title {
      margin-top: .5rem !important;
    }
    .date {
      max-width: 100% !important;
      margin-bottom: 1rem !important;
    }
    .img-cover {
      width: 100% !important;
      height: 15rem !important;
    }
  }
</style>
