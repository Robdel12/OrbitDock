import { computed, signal } from '@preact/signals'

const STORAGE_KEY = 'orbitdock_auth_token'

const token = signal(localStorage.getItem(STORAGE_KEY) || '')
const isAuthenticated = computed(() => token.value.length > 0)

const setToken = (value) => {
  const trimmed = (value || '').trim()
  token.value = trimmed
  if (trimmed) {
    localStorage.setItem(STORAGE_KEY, trimmed)
  } else {
    localStorage.removeItem(STORAGE_KEY)
  }
}

const clearToken = () => setToken('')

export { clearToken, isAuthenticated, setToken, token }
