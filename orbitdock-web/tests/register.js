import { register } from 'node:module'

register('./loader-hooks.js', import.meta.url)

// Set up DOM globals before any test file loads
await import('./setup.js')
