import { useMemo } from 'preact/hooks'
import { renderMarkdown } from '../../lib/markdown.js'
import styles from './assistant-row.module.css'

const AssistantRow = ({ entry }) => {
  const row = entry.row
  const html = useMemo(() => renderMarkdown(row.content), [row.content])

  return (
    <div class={styles.row}>
      <div class={styles.label}>Assistant</div>
      <div class={styles.content}>
        <div class={styles.markdown} dangerouslySetInnerHTML={{ __html: html }} />
        {row.is_streaming && (
          <>
            <span class={styles.cursor} />
            <span class={styles.dots} aria-label="Streaming">
              <span class={styles.dot} />
              <span class={styles.dot} />
              <span class={styles.dot} />
            </span>
          </>
        )}
      </div>
    </div>
  )
}

export { AssistantRow }
