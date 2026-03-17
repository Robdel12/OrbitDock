import { StatusDot } from '../ui/status-dot.jsx'
import { Badge } from '../ui/badge.jsx'
import { StatusIndicator } from './status-indicator.jsx'
import { formatRelativeTime } from '../../lib/format.js'
import styles from './session-card.module.css'

const SessionCard = ({ session, onClick }) => {
  const displayName =
    session.custom_name ||
    session.summary ||
    session.first_prompt ||
    session.id

  return (
    <button class={styles.card} onClick={onClick}>
      <div class={styles.header}>
        <StatusDot status={session.work_status} />
        <span class={styles.name}>{displayName}</span>
        <Badge variant="tool" color={`provider-${session.provider}`}>
          {session.provider}
        </Badge>
      </div>
      <div class={styles.meta}>
        <StatusIndicator workStatus={session.work_status} />
        {session.model && <span class={styles.model}>{session.model}</span>}
        {session.last_activity_at && (
          <span class={styles.time}>{formatRelativeTime(session.last_activity_at)}</span>
        )}
      </div>
    </button>
  )
}

export { SessionCard }
