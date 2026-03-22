import { signal } from '@preact/signals'

const STORAGE_KEY = 'orbitdock:viewMode'

const readStored = () => {
  try {
    return localStorage.getItem(STORAGE_KEY)
  } catch {
    return null
  }
}

const viewMode = signal(readStored() === 'verbose' ? 'verbose' : 'focused')

const setViewMode = (mode) => {
  viewMode.value = mode
  try {
    localStorage.setItem(STORAGE_KEY, mode)
  } catch {
    /* noop */
  }
}

const toggleViewMode = () => {
  setViewMode(viewMode.value === 'focused' ? 'verbose' : 'focused')
}

export { setViewMode, toggleViewMode, viewMode }
