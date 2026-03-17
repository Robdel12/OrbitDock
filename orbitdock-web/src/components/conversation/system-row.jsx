import styles from './system-row.module.css'

const SystemRow = ({ entry }) => {
  const row = entry.row
  return (
    <div class={styles.row}>
      <span class={styles.content}>{row.content}</span>
    </div>
  )
}

export { SystemRow }
