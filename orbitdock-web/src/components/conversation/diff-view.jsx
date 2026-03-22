import styles from './diff-view.module.css'

const DiffView = ({ lines }) => {
  if (!lines || lines.length === 0) return null

  return (
    <div class={styles.diff}>
      {lines.map((line, i) => {
        const kindClass =
          line.kind === 'addition' ? styles.added : line.kind === 'deletion' ? styles.removed : styles.context

        return (
          <div key={i} class={`${styles.line} ${kindClass}`}>
            <span class={styles.lineNum}>{line.old_line ?? ''}</span>
            <span class={styles.lineNum}>{line.new_line ?? ''}</span>
            <span class={styles.content}>{line.content}</span>
          </div>
        )
      })}
    </div>
  )
}

export { DiffView }
