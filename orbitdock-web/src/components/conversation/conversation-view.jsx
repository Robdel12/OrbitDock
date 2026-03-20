import { useEffect, useMemo } from 'preact/hooks'
import { useScrollAnchor } from '../../hooks/use-scroll-anchor.js'
import { viewMode } from '../../stores/view-mode.js'
import { groupToolRuns } from '../../lib/group-tool-runs.js'
import { RowDispatcher } from './row-dispatcher.jsx'
import { Spinner } from '../ui/spinner.jsx'
import { Skeleton } from '../ui/skeleton.jsx'
import styles from './conversation-view.module.css'

// ---------------------------------------------------------------------------
// Status phrases for the conversation-bottom indicator
// ---------------------------------------------------------------------------

const STATUS_CONFIG = {
  working: {
    label: 'Working',
    colorVar: '--color-status-working',
    animated: true,
  },
  waiting: {
    label: 'Waiting for input',
    colorVar: '--color-status-working',
    animated: true,
  },
  permission: {
    label: 'Awaiting clearance',
    colorVar: '--color-status-permission',
    animated: true,
  },
  question: {
    label: 'Standing by',
    colorVar: '--color-status-question',
    animated: true,
  },
  reply: {
    label: 'Ready for next mission',
    colorVar: '--color-status-reply',
    animated: false,
  },
  ended: {
    label: 'Mission Complete',
    colorVar: '--color-status-ended',
    animated: false,
  },
}

const StatusIndicator = ({ workStatus }) => {
  const config = STATUS_CONFIG[workStatus]
  if (!config) return null

  return (
    <div
      class={styles.statusIndicator}
      style={{ '--indicator-color': `var(${config.colorVar})` }}
    >
      <span class={`${styles.statusDot} ${config.animated ? styles.statusDotAnimated : ''}`} />
      <span class={styles.statusLabel}>{config.label}</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Scroll-to-bottom floating pill
// ---------------------------------------------------------------------------

const ScrollPill = ({ onClick, unreadCount }) => (
  <button class={styles.scrollPill} onClick={onClick}>
    {unreadCount > 0 && (
      <span class={styles.scrollPillBadge}>{unreadCount > 99 ? '99+' : unreadCount}</span>
    )}
    <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
      <path d="M5 2v6M2 5.5L5 8.5 8 5.5" />
    </svg>
    <span>New</span>
  </button>
)

// ---------------------------------------------------------------------------
// Main conversation view
// ---------------------------------------------------------------------------

// Props:
//   rows, isLoadingHistory, hasMoreBefore, onLoadOlder — data
//   scrollRef — optional { containerRef, sentinelRef, isPinned, scrollToBottom }
//   session — session object for status indicator
//   unreadCount — number of unread messages for the scroll pill badge
const ConversationView = ({
  rows,
  isLoadingHistory,
  hasMoreBefore,
  onLoadOlder,
  scrollRef,
  session,
  unreadCount = 0,
}) => {
  const internal = useScrollAnchor()
  const { containerRef, sentinelRef, isPinned, scrollToBottom } = scrollRef ?? internal

  // Derive display rows: apply tool grouping in focused mode.
  const displayRows = useMemo(() => {
    return viewMode.value === 'focused' ? groupToolRuns(rows) : rows
  }, [rows, viewMode.value])

  // Auto-scroll only when the user is already at the bottom (pinned).
  useEffect(() => {
    const id = requestAnimationFrame(() => {
      if (isPinned.peek()) scrollToBottom()
    })
    return () => cancelAnimationFrame(id)
  }, [rows])

  const handleScrollToBottom = () => {
    const el = containerRef.current
    if (el) el.scrollTo({ top: el.scrollHeight, behavior: 'smooth' })
  }

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
        {displayRows.length === 0 ? (
          <div class={styles.rowsSkeleton}>
            <div class={styles.skeletonRow}><Skeleton width="60%" height="14px" /><Skeleton width="90%" height="14px" /><Skeleton width="45%" height="14px" /></div>
            <div class={styles.skeletonRow}><Skeleton width="50%" height="14px" /></div>
            <div class={styles.skeletonRow}><Skeleton width="85%" height="14px" /><Skeleton width="70%" height="14px" /></div>
          </div>
        ) : displayRows.map((entry) => (
          <RowDispatcher key={`${entry.sequence}-${entry.row?.id || ''}`} entry={entry} />
        ))}
      </div>

      {/* Status indicator at bottom of conversation */}
      {session && <StatusIndicator workStatus={session.work_status} />}

      <div ref={sentinelRef} class={styles.sentinel} />

      {/* Floating scroll-to-bottom pill */}
      {!isPinned.value && (
        <ScrollPill onClick={handleScrollToBottom} unreadCount={unreadCount} />
      )}
    </div>
  )
}

export { ConversationView }
