import { Badge } from '../ui/badge.jsx'
import { Card } from '../ui/card.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './worker-row.module.css'

const WorkerRow = ({ entry }) => {
  const row = entry.row
  const payload = row.payload || {}
  const isRunning = payload.status === 'running' || payload.status === 'in_progress'

  return (
    <Card edgeColor="tool-task" class={styles.card}>
      <div class={styles.header}>
        <div class={styles.titleGroup}>
          {isRunning && <Spinner size="sm" />}
          <span class={styles.title}>{row.title}</span>
        </div>
        {payload.status && (
          <Badge variant="status" color={isRunning ? 'tool-task' : 'status-ended'}>
            {payload.status}
          </Badge>
        )}
      </div>
      {row.subtitle && <div class={styles.subtitle}>{row.subtitle}</div>}
      {payload.agent_type && (
        <div class={styles.meta}>
          <Badge variant="tool">{payload.agent_type}</Badge>
        </div>
      )}
    </Card>
  )
}

export { WorkerRow }
