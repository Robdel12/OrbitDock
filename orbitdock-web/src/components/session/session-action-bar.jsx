import styles from './session-action-bar.module.css'

const SessionActionBar = ({
  session,
}) => {
  const branch = session?.branch

  // Only render if there's metadata to show.
  if (!branch) return null

  return (
    <div class={styles.bar}>
      <div class={styles.left}>
        <span class={styles.metaItem} title={branch}>
          <svg class={styles.metaIcon} width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="5" cy="4" r="1.5" />
            <circle cx="5" cy="12" r="1.5" />
            <circle cx="11" cy="6" r="1.5" />
            <path d="M5 5.5v5M11 7.5c0 2-2 2.5-6 3" />
          </svg>
          <span class={styles.metaText}>{branch}</span>
        </span>
      </div>
    </div>
  )
}

export { SessionActionBar }
