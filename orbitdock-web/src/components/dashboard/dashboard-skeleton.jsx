import { Skeleton } from '../ui/skeleton.jsx'
import styles from './dashboard-skeleton.module.css'

// Mirrors the new dashboard layout while sessions are loading:
// page header (greeting + usage pills) → filter toolbar → zone-structured cards
const DashboardSkeleton = () => (
  <div class={styles.skeleton}>
    {/* Page header: greeting left + usage pills right */}
    <div class={styles.pageHeader}>
      <div class={styles.greeting}>
        <Skeleton width="180px" height="20px" />
        <Skeleton width="220px" height="12px" />
      </div>
      <div class={styles.usagePills}>
        <Skeleton width="120px" height="28px" radius="md" />
        <Skeleton width="100px" height="28px" radius="md" />
      </div>
    </div>

    {/* Filter toolbar */}
    <div class={styles.toolbar}>
      <Skeleton width="64px" height="36px" radius="lg" />
      <Skeleton width="72px" height="36px" radius="lg" />
      <Skeleton width="80px" height="36px" radius="lg" />
      <Skeleton width="64px" height="36px" radius="lg" />
      <div class={styles.toolbarSpacer} />
      <Skeleton width="90px" height="36px" radius="md" />
    </div>

    {/* Zone-structured cards */}
    <div class={styles.zones}>
      {/* Attention zone — 1 large card */}
      <div class={styles.zone}>
        <div class={styles.zoneHeader}>
          <Skeleton width="10px" height="10px" radius="lg" />
          <Skeleton width="120px" height="11px" />
          <Skeleton width="20px" height="16px" radius="lg" />
        </div>
        <AttentionCardSkeleton />
      </div>

      {/* Working zone — 2 medium cards */}
      <div class={styles.zone}>
        <div class={styles.zoneHeader}>
          <Skeleton width="10px" height="10px" radius="lg" />
          <Skeleton width="70px" height="11px" />
          <Skeleton width="20px" height="16px" radius="lg" />
        </div>
        <div class={styles.workingGrid}>
          <WorkingCardSkeleton nameWidth="65%" />
          <WorkingCardSkeleton nameWidth="80%" />
        </div>
      </div>

      {/* Ready zone — 3 compact rows */}
      <div class={styles.zone}>
        <div class={styles.zoneHeader}>
          <Skeleton width="10px" height="10px" radius="lg" />
          <Skeleton width="50px" height="11px" />
          <Skeleton width="20px" height="16px" radius="lg" />
        </div>
        <ReadyCardSkeleton nameWidth="75%" />
        <ReadyCardSkeleton nameWidth="55%" />
        <ReadyCardSkeleton nameWidth="90%" />
      </div>
    </div>
  </div>
)

const AttentionCardSkeleton = () => (
  <div class={styles.cardAttention}>
    <div class={styles.cardAttentionBar} />
    <div class={styles.cardAttentionBody}>
      <div class={styles.cardRow}>
        <Skeleton width="8px" height="8px" radius="lg" />
        <Skeleton width="160px" height="14px" />
        <div class={styles.cardSpacer} />
        <Skeleton width="48px" height="18px" radius="md" />
      </div>
      <div class={styles.cardRow}>
        <Skeleton width="200px" height="12px" />
        <Skeleton width="80px" height="12px" />
      </div>
      <Skeleton width="90%" height="11px" />
    </div>
  </div>
)

const WorkingCardSkeleton = ({ nameWidth }) => (
  <div class={styles.cardWorking}>
    <div class={styles.cardWorkingBar} />
    <div class={styles.cardWorkingBody}>
      <div class={styles.cardRow}>
        <Skeleton width="6px" height="6px" radius="lg" />
        <Skeleton width={nameWidth} height="13px" />
        <div class={styles.cardSpacer} />
        <Skeleton width="44px" height="16px" radius="md" />
      </div>
      <Skeleton width="60%" height="10px" />
    </div>
  </div>
)

const ReadyCardSkeleton = ({ nameWidth }) => (
  <div class={styles.cardReady}>
    <div class={styles.cardRow}>
      <Skeleton width="6px" height="6px" radius="lg" />
      <Skeleton width={nameWidth} height="13px" />
      <div class={styles.cardSpacer} />
      <Skeleton width="40px" height="16px" radius="md" />
      <Skeleton width="28px" height="10px" />
    </div>
  </div>
)

export { DashboardSkeleton }
