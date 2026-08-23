<script>
  import { tick } from 'svelte'
  import { modal } from '@/modules/navigation.js'

  export let id
  export let showModal
  export let shouldRender = false
  export let close
  export let css = ''
  export let innerCss = ''

  let content
  /** Where focus was when the dialog opened, to hand it back on close — without this,
   * closing any modal dropped keyboard users at <body>. */
  let opener = null

  $: onVisibility(showModal)
  async function onVisibility (open) {
    if (typeof document === 'undefined') return
    if (open) {
      opener = document.activeElement
      await tick()
      // initial focus lands on the dialog's first focusable thing, or the dialog itself
      const target = content?.querySelector('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])') || content
      target?.focus?.({ preventScroll: true })
    } else if (opener) {
      opener.focus?.({ preventScroll: true })
      opener = null
    }
  }

  function handleKeydown(event) {
    if (!showModal || !modal.focused || modal.focused !== id) return
    if (event.key === 'Escape') {
      const target = event.target
      if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable) {
        target.blur()
        event.preventDefault()
      } else close()
      return
    }
    // a minimal trap: Tab wraps within the dialog instead of walking into the page behind
    if (event.key === 'Tab' && content) {
      const focusable = [...content.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')]
        .filter(element => !element.disabled && element.offsetParent !== null)
      if (!focusable.length) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]
      if (event.shiftKey && document.activeElement === first) {
        last.focus()
        event.preventDefault()
      } else if (!event.shiftKey && document.activeElement === last) {
        first.focus()
        event.preventDefault()
      }
    }
  }
</script>

<svelte:window on:keydown={handleKeydown} />

<div class='modal-soft position-absolute d-flex align-items-center justify-content-center z-50 w-full h-full {css}' class:hide={!showModal} class:show={showModal} id={`${id}_modal`}>
  <div class='modal-soft-dialog d-flex align-items-center justify-content-center pt-md-wh-40 {innerCss}' tabindex='-1' class:hide={!showModal} class:show={showModal} on:pointerdown|self={close}>
    <div bind:this={content} class='overflow-hidden d-flex flex-column overflow-y-scroll {$$restProps.class}' role='dialog' aria-modal='true' tabindex='-1'>
      {#if showModal || shouldRender}
        <slot />
      {/if}
    </div>
  </div>
</div>

<style>
  .modal-soft {
    background-color: hsla(var(--black-color-hsl), 0.85);
    transition: opacity var(--motion-panel) var(--ease-settle), visibility var(--motion-panel) var(--ease-settle);
  }
  .modal-soft.show {
    visibility: visible;
    opacity: 1;
  }
  .modal-soft.hide {
    visibility: hidden;
    opacity: 0;
  }
  .modal-soft-dialog {
    width: 100%;
    height: 100%;
    transition: transform var(--motion-panel) var(--ease-settle);
    transform-origin: bottom center;
  }
  .modal-soft-dialog.show {
    transform: scale(1);
  }
  .modal-soft-dialog.hide {
    transform: scale(0.95);
  }
  .modal-soft-dialog:focus-visible {
    box-shadow: unset !important;
  }
</style>