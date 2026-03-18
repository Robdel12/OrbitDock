import { useEffect, useRef } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { toasts, removeToast } from '../../stores/toasts.js'
import styles from './toast-container.module.css'

const TOAST_LIFETIME_MS = 5000
const TICK_INTERVAL_MS = 1000

// Edge color CSS variable for each toast type
const EDGE_COLORS = {
  attention: 'var(--color-accent)',
  info: 'var(--color-feedback-positive)',
  error: 'var(--color-feedback-negative)',
}

// ── Toast ─────────────────────────────────────────────────────────────────────

const Toast = ({ toast, onDismiss, onClick }) => {
  const edgeColor = EDGE_COLORS[toast.type] ?? EDGE_COLORS.info

  const handleClick = () => {
    if (toast.sessionId) onClick(toast.sessionId)
  }

  return (
    <div
      class={`${styles.toast} ${toast.sessionId ? styles.clickable : ''}`}
      role="status"
      aria-live="polite"
      onClick={handleClick}
    >
      <div class={styles.edge} style={{ background: edgeColor }} />
      <div class={styles.body}>
        <span class={styles.title}>{toast.title}</span>
        {toast.body && <span class={styles.message}>{toast.body}</span>}
      </div>
      <button
        class={styles.dismiss}
        aria-label="Dismiss notification"
        onClick={(e) => {
          e.stopPropagation()
          onDismiss(toast.id)
        }}
      >
        ×
      </button>
    </div>
  )
}

// ── ToastContainer ────────────────────────────────────────────────────────────

const ToastContainer = () => {
  const [, navigate] = useLocation()
  const intervalRef = useRef(null)
  const list = toasts.value

  // Manage a single interval that ticks every second to expire old toasts.
  // Start it when the first toast arrives; clear it when the list empties.
  useEffect(() => {
    if (list.length > 0 && intervalRef.current === null) {
      intervalRef.current = setInterval(() => {
        const now = Date.now()
        for (const t of toasts.value) {
          if (now - t.createdAt > TOAST_LIFETIME_MS) {
            removeToast(t.id)
          }
        }
      }, TICK_INTERVAL_MS)
    }

    if (list.length === 0 && intervalRef.current !== null) {
      clearInterval(intervalRef.current)
      intervalRef.current = null
    }
  }, [list.length])

  // Ensure the interval is always cleaned up when the component unmounts.
  useEffect(() => {
    return () => {
      if (intervalRef.current !== null) {
        clearInterval(intervalRef.current)
        intervalRef.current = null
      }
    }
  }, [])

  if (list.length === 0) return null

  const handleNavigate = (sessionId) => {
    navigate(`/session/${sessionId}`)
  }

  return (
    <div class={styles.container} aria-label="Notifications">
      {list.map((toast) => (
        <Toast
          key={toast.id}
          toast={toast}
          onDismiss={removeToast}
          onClick={handleNavigate}
        />
      ))}
    </div>
  )
}

export { ToastContainer }
