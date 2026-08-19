import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))

// Renderer build. Node-target bundles (electron background/preload/main,
// capacitor nodejs) remain on webpack until their code moves to Rust.
export default defineConfig(({ mode }) => ({
  root: here,
  // production output is loaded over file:// by Electron, so assets must be relative
  base: './',
  publicDir: join(here, 'public'),
  plugins: [
    svelte({
      compilerOptions: { dev: mode === 'development' }
    })
  ],
  resolve: {
    alias: {
      '@': here,
      'bittorrent-tracker/lib/client/websocket-tracker.js': join(here, '../node_modules/bittorrent-tracker/lib/client/websocket-tracker.js'),
      debug: join(here, 'modules/lib/debug.js'),
      module: join(here, 'vite-shims/empty.js'),
      url: join(here, 'vite-shims/empty.js')
    },
    extensions: ['.mjs', '.js', '.svelte']
  },
  worker: {
    format: 'es'
  },
  server: {
    port: 5173,
    strictPort: true,
    host: 'localhost'
  },
  build: {
    outDir: join(here, '../electron/build'),
    emptyOutDir: false,
    target: 'chrome128',
    sourcemap: true,
    rollupOptions: {
      input: { app: join(here, 'app.html') }
    }
  }
}))
