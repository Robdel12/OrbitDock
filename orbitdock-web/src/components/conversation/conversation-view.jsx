import { useEffect } from 'preact/hooks'
import { useScrollAnchor } from '../../hooks/use-scroll-anchor.js'
import { RowDispatcher } from './row-dispatcher.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './conversation-view.module.css'

const ConversationView = ({ rows, isLoadingHistory, hasMoreBefore, onLoadOlder }) => {
  const { containerRef, sentinelRef, isPinned, scrollToBottom } = useScrollAnchor()

  useEffect(() => {
    if (isPinned.value) scrollToBottom()
  }, [rows])

  return (
    <div class={styles.container} ref={containerRef}>
      {hasMoreBefore && (
        <div class={styles.loadMore}>
          {isLoadingHistory ? (
            <Spinner size="sm" />
          ) : (
            <button class={styles.loadButton} onClick={onLoadOlder}>
              Load older messages
            </button>
          )}
        </div>
      )}
      <div class={styles.rows}>
        {rows.map((entry) => (
          <RowDispatcher key={`${entry.sequence}-${entry.row?.id || ''}`} entry={entry} />
        ))}
      </div>
      <div ref={sentinelRef} class={styles.sentinel} />
      {!isPinned.value && (
        <button class={styles.jumpBottom} onClick={scrollToBottom}>
          Jump to bottom
        </button>
      )}
    </div>
  )
}

export { ConversationView }
