import styles from './hook-row.module.css'

const HookRow = ({ entry }) => {
  const row = entry.row
  return (
    <div class={styles.row}>
      <span class={styles.title}>{row.title}</span>
      {row.subtitle && <span class={styles.subtitle}> — {row.subtitle}</span>}
    </div>
  )
}

export { HookRow }
