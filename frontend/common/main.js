import '@/polyfills.js'
import 'quartermoon/css/quartermoon-variables.css'
import '@fontsource-variable/nunito'
import { cacheReady, migrationStatus } from '@/modules/cache.js'
import { SUPPORTS } from '@/modules/support.js'
import { COMMON } from '@/modules/bridge.js'
import { attachDiagnostics, debugLogging } from '@/modules/lib/diagnostics.js'
import Debug from 'debug'
import '@/css.css'
import '@/themes.css'
import '@/typography.css'

// the page's own diagnostics go where the user can export them; the host's boot-time
// capture hands over here so nothing is logged twice
attachDiagnostics({ send: COMMON.log, verbose: debugLogging, debug: Debug })
window.__SHIRU_BOOT_LOG__?.stop()

let splash
if (!SUPPORTS.isAndroid && await COMMON.isWindowVisible()) {
  const { default: Splash } = await import('./Splash.svelte')
  splash = new Splash({ target: document.body })
}

let migration = null
const unsubscribe = migrationStatus.subscribe(value => {
  if (value !== null && !migration) {
    import('./Migration.svelte').then(({ default: Migration }) => {
      migration = new Migration({ target: document.body })
    })
  }
})

await cacheReady()
unsubscribe()
const target = migration ?? splash
if (target) {
  target.$set({ done: true })
  setTimeout(() => target.$destroy(), 900).unref?.()
}

const { default: App } = await import('./App.svelte')
new App({ target: document.body })