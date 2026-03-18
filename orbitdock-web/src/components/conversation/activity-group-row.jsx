import { useState } from 'preact/hooks'
import { RowDispatcher } from './row-dispatcher.jsx'
import { Badge } from '../ui/badge.jsx'
import styles from './activity-group-row.module.css'

const ActivityGroupRow = ({ entry }) => {
  const row = entry.row
  const [expanded, setExpanded] = useState(false)

  const toolTypeSummary = row.children ? buildToolTypeSummary(row.children) : null

  return (
    <div class={styles.group}>
      <button
        class={styles.header}
        onClick={() => setExpanded(!expanded)}
      >
        <svg class={styles.icon} width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style={expanded ? { transform: 'rotate(90deg)' } : undefined}>
          <path d="M3.5 2L6.5 5L3.5 8" />
        </svg>
        <span class={styles.title}>{row.title}</span>
        {row.tool_count != null && (
          <Badge variant="meta">{row.tool_count} tools</Badge>
        )}
      </button>
      {toolTypeSummary && !expanded && (
        <div class={styles.toolSummary}>{toolTypeSummary}</div>
      )}
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

/**
 * Build a compact summary like "Read • Edit • Bash" from child tool entries.
 */
const buildToolTypeSummary = (children) => {
  const seen = new Set()
  const names = []
  for (const child of children) {
    const name = child.row?.tool_display?.summary
    if (name && !seen.has(name)) {
      seen.add(name)
      names.push(name)
    }
  }
  if (names.length === 0) return null
  return names.join(' \u2022 ')
}

export { ActivityGroupRow }
