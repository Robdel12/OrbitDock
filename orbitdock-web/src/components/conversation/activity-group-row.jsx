import { useState } from 'preact/hooks'
import { RowDispatcher } from './row-dispatcher.jsx'
import { Badge } from '../ui/badge.jsx'
import styles from './activity-group-row.module.css'

const ActivityGroupRow = ({ entry }) => {
  const row = entry.row
  const [expanded, setExpanded] = useState(false)

  return (
    <div class={styles.group}>
      <button
        class={styles.header}
        onClick={() => setExpanded(!expanded)}
      >
        <span class={styles.icon}>{expanded ? '▾' : '▸'}</span>
        <span class={styles.title}>{row.title}</span>
        {row.tool_count != null && (
          <Badge variant="meta">{row.tool_count} tools</Badge>
        )}
      </button>
      {expanded && row.children && (
        <div class={styles.children}>
          {row.children.map((child) => (
            <RowDispatcher key={`${child.sequence}-${child.row?.id || ''}`} entry={child} />
          ))}
        </div>
      )}
    </div>
  )
}

export { ActivityGroupRow }
