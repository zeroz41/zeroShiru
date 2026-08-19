import { toast } from 'svelte-sonner'

export function copyToClipboard(text, detail) {
  if (!text) return
  navigator.clipboard.writeText(text)
  toast('Copied to clipboard', {
    description: `Copied${detail ? ` ${detail}` : ''} to clipboard`,
    duration: 5_000
  })
}

export default new class extends EventTarget {
  constructor () {
    super()
    window.addEventListener('drop', this.handleTransfer.bind(this))
    window.addEventListener('paste', this.handleTransfer.bind(this))
    window.addEventListener('dragover', e => e.preventDefault())
  }

  async handleTransfer ({ dataTransfer, clipboardData }) {
    const promises = [...(dataTransfer || clipboardData).items].map(item => {
      const type = item.type
      return new Promise(resolve => item.kind === 'string' ? item.getAsString(text => resolve({ text, type })) : resolve(item.getAsFile()))
    })

    const items = await Promise.all(promises)

    const files = []
    const text = []
    for (const item of items) {
      if (item instanceof Blob) {
        files.push(item)
      } else {
        text.push(item)
      }
    }
    if (files.length) this.dispatchEvent(new CustomEvent('files', { detail: files }))
    if (text.length) this.dispatchEvent(new CustomEvent('text', { detail: text }))
  }
}()