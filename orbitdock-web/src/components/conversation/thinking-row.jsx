import { useState, useMemo } from 'preact/hooks'
import styles from './thinking-row.module.css'

const ThinkingRow = ({ entry }) => {
  const row = entry.row
  const [expanded, setExpanded] = useState(false)

  const preview = useMemo(() => {
    if (!row.content) return ''
    const first = row.content.trim().split('\n')[0]
    return first.length > 100 ? first.slice(0, 100) + '...' : first
  }, [row.content])

  return (
    <div class={styles.row}>
      <button
        class={styles.toggle}
        onClick={() => setExpanded(!expanded)}
      >
        <svg class={styles.chevron} width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style={expanded ? { transform: 'rotate(90deg)' } : undefined}>
          <path d="M3.5 2L6.5 5L3.5 8" />
        </svg>
        <span class={styles.label}>Thinking</span>
        {!expanded && preview && (
          <span class={styles.preview}>{preview}</span>
        )}
      </button>
      {expanded && (
        <div class={styles.content}>{row.content}</div>
      )}
    </div>
  )
}

export { ThinkingRow }
