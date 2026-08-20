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
    preserveSymlinks: true,
    alias: {
      '@': here,
      'bittorrent-tracker/lib/client/websocket-tracker.js': join(here, '../node_modules/bittorrent-tracker/lib/client/websocket-tracker.js'),
      debug: join(here, 'modules/lib/debug.js'),
      events: join(here, 'vite-shims/events.js'),
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
    outDir: join(here, '../../dist/web'),
    // vite refuses to clean an outDir outside the project root unless told to, and left
    // alone this one kept every chunk of every build ever made: 699 files and 293MB, all
    // but a handful of them unreachable, every one of them shipped inside the installers
    emptyOutDir: true,
    target: 'chrome128',
    sourcemap: true,
    rollupOptions: {
      input: { app: join(here, 'app.html') }
    }
  }
}))
