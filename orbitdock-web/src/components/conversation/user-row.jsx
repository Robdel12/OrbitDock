import { useMemo } from 'preact/hooks'
import { renderMarkdown } from '../../lib/markdown.js'
import styles from './user-row.module.css'

const imageUrl = (img, sessionId) => {
  if (img.input_type === 'attachment' && sessionId) {
    return `/api/sessions/${sessionId}/attachments/images/${img.value}`
  }
  // data-URI or remote URL
  return img.value
}

const UserRow = ({ entry }) => {
  const row = entry.row
  const html = useMemo(() => renderMarkdown(row.content), [row.content])
  const images = row.images?.length ? row.images : null

  return (
    <div class={styles.row}>
      <div class={styles.label}>You</div>
      <div class={styles.bubble}>
        {images && (
          <div class={styles.images}>
            {images.map((img, i) => (
              <img
                key={i}
                src={imageUrl(img, entry.session_id)}
                alt={img.display_name || 'Attached image'}
                class={styles.image}
                loading="lazy"
              />
            ))}
          </div>
        )}
        {row.content && <div class={styles.content} dangerouslySetInnerHTML={{ __html: html }} />}
      </div>
    </div>
  )
}

export { UserRow }
