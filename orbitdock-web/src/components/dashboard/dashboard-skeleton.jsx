import { Skeleton } from '../ui/skeleton.jsx'
import styles from './dashboard-skeleton.module.css'

// Mirrors the dashboard layout while sessions are loading:
// usage summary bar → filter toolbar → session cards grouped by repo
const DashboardSkeleton = () => (
  <div class={styles.skeleton}>
    {/* Usage summary */}
    <div class={styles.usageBar}>
      <Skeleton width="140px" height="12px" />
      <Skeleton width="200px" height="8px" radius="sm" />
      <Skeleton width="80px" height="12px" />
    </div>

    {/* Filter toolbar */}
    <div class={styles.toolbar}>
      <Skeleton width="80px" height="28px" radius="md" />
      <Skeleton width="80px" height="28px" radius="md" />
      <Skeleton width="80px" height="28px" radius="md" />
      <div class={styles.toolbarSpacer} />
      <Skeleton width="100px" height="28px" radius="md" />
    </div>

    {/* Session groups */}
    <div class={styles.groups}>
      <SessionGroupSkeleton label cardCount={3} widths={['75%', '55%', '90%']} />
      <SessionGroupSkeleton label cardCount={2} widths={['60%', '80%']} />
    </div>
  </div>
)

const SessionGroupSkeleton = ({ cardCount, widths }) => (
  <div class={styles.group}>
    {/* Group header (repo name) */}
    <div class={styles.groupHeader}>
      <Skeleton width="160px" height="11px" />
    </div>
    {/* Card rows */}
    {Array.from({ length: cardCount }, (_, i) => (
      <SessionCardSkeleton key={i} nameWidth={widths[i] || '70%'} />
    ))}
  </div>
)

const SessionCardSkeleton = ({ nameWidth }) => (
  <div class={styles.card}>
    {/* Header row: dot + name + badge */}
    <div class={styles.cardHeader}>
      <Skeleton width="8px" height="8px" radius="lg" />
      <Skeleton width={nameWidth} height="14px" />
      <Skeleton width="48px" height="18px" radius="md" />
    </div>
    {/* Meta row */}
    <div class={styles.cardMeta}>
      <Skeleton width="70px" height="11px" />
      <Skeleton width="40px" height="11px" />
    </div>
  </div>
)

export { DashboardSkeleton }
