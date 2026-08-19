// matroska-metadata (debrid subtitle parsing) expects Node's Buffer global, which
// browser targets lack. Webpack builds inject it via ProvidePlugin; Vite builds
// rely on this module being the first import in main.js.
import { Buffer } from 'buffer'
globalThis.Buffer ??= Buffer
