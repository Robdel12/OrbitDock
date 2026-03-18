import styles from './session-action-bar.module.css'

const SessionActionBar = ({
  session,
  isPinned,
  unreadCount,
  onScrollToBottom,
}) => {
  const branch = session?.branch
  const hasMeta = !!branch

  // Only render if there's metadata to show or if scroll button is needed.
  if (hasMeta || !isPinned) {
    return (
      <div class={styles.bar}>
        <div class={styles.left}>
          {branch && (
            <span class={styles.metaItem} title={branch}>
              <svg class={styles.metaIcon} width="12" height="12" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
                <circle cx="5" cy="4" r="1.5" />
                <circle cx="5" cy="12" r="1.5" />
                <circle cx="11" cy="6" r="1.5" />
                <path d="M5 5.5v5M11 7.5c0 2-2 2.5-6 3" />
              </svg>
              <span class={styles.metaText}>{branch}</span>
            </span>
          )}
        </div>

        {!isPinned && (
          <button class={styles.scrollBtn} onClick={onScrollToBottom}>
            {unreadCount > 0 && (
              <span class={styles.badge}>{unreadCount > 99 ? '99+' : unreadCount}</span>
            )}
            <svg class={styles.scrollIcon} width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
              <path d="M6 2v8M3 7l3 3 3-3" />
            </svg>
            <span class={styles.scrollLabel}>New</span>
          </button>
        )}
      </div>
    )
  }

  return null
}

export { SessionActionBar }
