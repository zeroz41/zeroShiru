// Installs the alias/shim resolution hooks before any test file loads.
// Every test command passes this via --import, see package.json.
import { register } from 'node:module'
register('./loader.js', import.meta.url)
