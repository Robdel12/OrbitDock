import { connectionState } from '../../stores/connection.js'
import styles from './header.module.css'

const STATUS_LABELS = {
  connected: 'Connected',
  connecting: 'Connecting...',
  disconnected: 'Disconnected',
  reconnecting: 'Reconnecting...',
  failed: 'Connection Failed',
}

const Header = () => {
  const state = connectionState.value
  const label = STATUS_LABELS[state] || state

  return (
    <header class={styles.header}>
      <div class={styles.status}>
        <span
          class={styles.dot}
          style={{
            background:
              state === 'connected'
                ? 'var(--color-feedback-positive)'
                : state === 'failed'
                  ? 'var(--color-feedback-negative)'
                  : 'var(--color-feedback-caution)',
          }}
        />
        <span class={styles.label}>{label}</span>
      </div>
    </header>
  )
}

export { Header }
