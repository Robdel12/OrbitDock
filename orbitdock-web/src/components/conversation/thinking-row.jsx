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
        <span class={styles.icon}>{expanded ? '▾' : '▸'}</span>
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
