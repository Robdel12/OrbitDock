import { StatusDot } from '../ui/status-dot.jsx'
import { StatusIndicator } from './status-indicator.jsx'
import { Badge } from '../ui/badge.jsx'
import { Button } from '../ui/button.jsx'
import styles from './session-header.module.css'

const SessionHeader = ({ session, onInterrupt, onCompact, onUndo, onEnd }) => {
  if (!session) return null

  const displayName = session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`
  const isActive = session.status === 'active'
  const isWorking = session.work_status === 'working'

  return (
    <div class={styles.header}>
      <div class={styles.info}>
        <StatusDot status={session.work_status} />
        <span class={styles.name}>{displayName}</span>
        <StatusIndicator workStatus={session.work_status} />
        {session.model && (
          <Badge variant="tool" color={`provider-${session.provider}`}>
            {session.model}
          </Badge>
        )}
      </div>
      {isActive && (
        <div class={styles.actions}>
          {isWorking && (
            <Button variant="danger" size="sm" onClick={onInterrupt}>
              Interrupt
            </Button>
          )}
          <Button variant="ghost" size="sm" onClick={onUndo}>
            Undo
          </Button>
          <Button variant="ghost" size="sm" onClick={onCompact}>
            Compact
          </Button>
          <Button variant="ghost" size="sm" onClick={onEnd}>
            End
          </Button>
        </div>
      )}
    </div>
  )
}

export { SessionHeader }
