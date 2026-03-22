import { afterEach } from 'node:test'
import { cleanup } from '@testing-library/preact'
import { GlobalWindow } from 'happy-dom'

const window = new GlobalWindow({ url: 'http://localhost' })

// Install browser globals that Preact and testing-library expect.
// Some globals (e.g. navigator) are read-only on globalThis in Node 24+,
// so we use Object.defineProperty with a fallback.
const globals = [
  'document',
  'navigator',
  'HTMLElement',
  'Element',
  'Node',
  'Event',
  'CustomEvent',
  'MutationObserver',
  'requestAnimationFrame',
  'cancelAnimationFrame',
  'getComputedStyle',
  'Text',
  'DocumentFragment',
  'Comment',
  'CSSStyleDeclaration',
  'DOMParser',
  'HTMLTemplateElement',
  'HTMLUnknownElement',
  'localStorage',
  'sessionStorage',
]

for (const name of globals) {
  if (!(name in window)) continue
  try {
    Object.defineProperty(globalThis, name, {
      value: window[name],
      writable: true,
      configurable: true,
    })
  } catch {
    // Some properties on globalThis may be non-configurable — skip them
  }
}

globalThis.window = window

afterEach(() => {
  cleanup()
})
