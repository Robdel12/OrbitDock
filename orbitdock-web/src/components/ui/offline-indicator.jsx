import { connectionState } from '../../stores/connection.js'
import styles from './offline-indicator.module.css'

// Shows a fixed bar at the top of the viewport when the WS connection is lost.
// Uses the connectionState signal directly — no props needed.
const OfflineIndicator = () => {
  const state = connectionState.value

  // Only show when disconnected or in error state (not while actively connecting)
  const isVisible = state === 'disconnected' || state === 'error'

  if (!isVisible) return null

  const label = state === 'error' ? 'Connection error' : 'Disconnected'

  return (
    <div class={styles.bar} role="status" aria-live="polite">
      <span class={styles.dot} aria-hidden="true" />
      <span class={styles.label}>{label} — reconnecting…</span>
    </div>
  )
}

export { OfflineIndicator }
