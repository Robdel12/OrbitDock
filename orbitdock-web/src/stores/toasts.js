import { signal } from '@preact/signals'

// Toast shape: { id, title, body, type, sessionId, createdAt }
// type: 'attention' | 'info' | 'error'
const toasts = signal([])
const MAX_VISIBLE = 3

const addToast = ({ title, body, type = 'info', sessionId = null }) => {
  const id = crypto.randomUUID()
  const toast = { id, title, body, type, sessionId, createdAt: Date.now() }
  toasts.value = [toast, ...toasts.value].slice(0, MAX_VISIBLE)
  return id
}

const removeToast = (id) => {
  toasts.value = toasts.value.filter((t) => t.id !== id)
}

export { toasts, addToast, removeToast }
