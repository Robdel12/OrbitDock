import { useMemo } from 'preact/hooks'
import { renderMarkdown } from '../../lib/markdown.js'
import styles from './user-row.module.css'

const UserRow = ({ entry }) => {
  const row = entry.row
  const html = useMemo(() => renderMarkdown(row.content), [row.content])

  return (
    <div class={styles.row}>
      <div class={styles.bubble}>
        <div class={styles.content} dangerouslySetInnerHTML={{ __html: html }} />
      </div>
    </div>
  )
}

export { UserRow }
