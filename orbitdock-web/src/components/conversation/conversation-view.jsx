import { useEffect, useMemo } from 'preact/hooks'
import { useScrollAnchor } from '../../hooks/use-scroll-anchor.js'
import { viewMode } from '../../stores/view-mode.js'
import { groupToolRuns } from '../../lib/group-tool-runs.js'
import { RowDispatcher } from './row-dispatcher.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './conversation-view.module.css'

// Props:
//   rows, isLoadingHistory, hasMoreBefore, onLoadOlder — data
//   scrollRef — optional { containerRef, sentinelRef, isPinned, scrollToBottom }
//     When provided the caller owns the scroll anchor (so session.jsx can read isPinned).
//     When omitted the component manages its own internal anchor.
const ConversationView = ({
  rows,
  isLoadingHistory,
  hasMoreBefore,
  onLoadOlder,
  scrollRef,
}) => {
  const internal = useScrollAnchor()
  const { containerRef, sentinelRef, isPinned, scrollToBottom } = scrollRef ?? internal

  // Derive display rows: apply tool grouping in focused mode.
  const displayRows = useMemo(() => {
    return viewMode.value === 'focused' ? groupToolRuns(rows) : rows
  }, [rows, viewMode.value])

  // Auto-scroll only when the user is already at the bottom (pinned).
  // Use peek() to avoid reacting to signal changes, and defer to rAF so the
  // IntersectionObserver has time to update isPinned after layout.
  useEffect(() => {
    const id = requestAnimationFrame(() => {
      if (isPinned.peek()) scrollToBottom()
    })
    return () => cancelAnimationFrame(id)
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
        {displayRows.map((entry) => (
          <RowDispatcher key={`${entry.sequence}-${entry.row?.id || ''}`} entry={entry} />
        ))}
      </div>
      <div ref={sentinelRef} class={styles.sentinel} />
      {!isPinned.value && (
        <button
          class={styles.jumpBottom}
          onClick={() => {
            const el = containerRef.current
            if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
          }}
        >
          Jump to bottom
        </button>
      )}
    </div>
  )
}

export { ConversationView }
