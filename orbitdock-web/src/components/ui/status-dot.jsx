import styles from './status-dot.module.css'

const STATUS_COLORS = {
  working: 'status-working',
  waiting: 'status-reply',
  permission: 'status-permission',
  question: 'status-question',
  reply: 'status-reply',
  ended: 'status-ended',
}

const StatusDot = ({ status }) => {
  const colorVar = STATUS_COLORS[status] || 'status-ended'
  return (
    <span
      class={`${styles.dot} ${status === 'working' ? styles.pulse : ''}`}
      style={{ background: `var(--color-${colorVar})` }}
      role="status"
      aria-label={status}
    />
  )
}

export { StatusDot }
