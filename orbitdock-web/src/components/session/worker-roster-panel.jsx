import { useState } from 'preact/hooks'
import { Spinner } from '../ui/spinner.jsx'
import { Badge } from '../ui/badge.jsx'
import styles from './worker-roster-panel.module.css'

// Derive a stable worker list from conversation rows.
// Each worker row may be upserted multiple times — the latest entry wins.
// Returns an array of { id, title, subtitle, status, agentType }.
const buildWorkerList = (rows) => {
  const map = new Map()
  for (const entry of rows) {
    const row = entry.row
    if (!row || row.row_type !== 'worker') continue
    const payload = row.payload || {}
    map.set(row.id, {
      id: row.id,
      title: row.title || 'Worker',
      subtitle: row.subtitle || null,
      status: payload.status || 'running',
      agentType: payload.agent_type || null,
    })
  }
  return [...map.values()]
}

const workerStatusColor = (status) => {
  if (status === 'running' || status === 'in_progress') return 'status-working'
  if (status === 'completed' || status === 'done') return 'feedback-positive'
  if (status === 'failed' || status === 'error') return 'feedback-negative'
  return 'status-ended'
}

const WorkerItem = ({ worker }) => {
  const isRunning = worker.status === 'running' || worker.status === 'in_progress'

  return (
    <div class={styles.worker}>
      <div class={styles.workerLeft}>
        {isRunning ? (
          <Spinner size="sm" />
        ) : (
          <span class={`${styles.workerDot} ${styles[`dot-${workerStatusColor(worker.status).replace(/-/g, '_')}`]}`} />
        )}
        <div class={styles.workerInfo}>
          <span class={styles.workerTitle}>{worker.title}</span>
          {worker.subtitle && (
            <span class={styles.workerSubtitle}>{worker.subtitle}</span>
          )}
        </div>
      </div>
      <div class={styles.workerRight}>
        {worker.agentType && (
          <Badge variant="tool">{worker.agentType}</Badge>
        )}
        <Badge variant="status" color={workerStatusColor(worker.status)}>
          {worker.status}
        </Badge>
      </div>
    </div>
  )
}

const WorkerRosterPanel = ({ rows }) => {
  const [collapsed, setCollapsed] = useState(false)

  const workers = buildWorkerList(rows)
  if (workers.length === 0) return null

  const runningCount = workers.filter(
    (w) => w.status === 'running' || w.status === 'in_progress'
  ).length

  return (
    <div class={styles.panel}>
      <button
        class={styles.toggle}
        onClick={() => setCollapsed((v) => !v)}
        aria-expanded={!collapsed}
      >
        <span class={styles.toggleIcon}>{collapsed ? '▶' : '▼'}</span>
        <span class={styles.toggleLabel}>
          Sub-agents
          <span class={styles.toggleCount}>{workers.length}</span>
        </span>
        {runningCount > 0 && (
          <span class={styles.activeIndicator}>
            <Spinner size="sm" />
            <span class={styles.activeLabel}>{runningCount} running</span>
          </span>
        )}
      </button>

      {!collapsed && (
        <div class={styles.list}>
          {workers.map((worker) => (
            <WorkerItem key={worker.id} worker={worker} />
          ))}
        </div>
      )}
    </div>
  )
}

export { WorkerRosterPanel }
