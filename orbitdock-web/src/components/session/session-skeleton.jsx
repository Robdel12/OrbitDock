import { Skeleton } from '../ui/skeleton.jsx'
import styles from './session-skeleton.module.css'

// Mirrors the layout of the session page while conversation is loading:
// header bar → status strip → a series of conversation rows
const SessionSkeleton = () => (
  <div class={styles.skeleton}>
    {/* Header bar */}
    <div class={styles.header}>
      <Skeleton width="180px" height="16px" />
      <div class={styles.headerRight}>
        <Skeleton width="60px" height="28px" radius="md" />
        <Skeleton width="60px" height="28px" radius="md" />
      </div>
    </div>

    {/* Status strip */}
    <div class={styles.strip}>
      <Skeleton width="100px" height="12px" />
      <Skeleton width="80px" height="12px" />
    </div>

    {/* Conversation rows */}
    <div class={styles.rows}>
      <ConvRowSkeleton side="user" widths={['72%']} />
      <ConvRowSkeleton side="assistant" widths={['90%', '65%', '80%']} />
      <ConvRowSkeleton side="user" widths={['55%']} />
      <ConvRowSkeleton side="assistant" widths={['88%', '70%', '50%', '75%']} />
      <ConvRowSkeleton side="assistant" widths={['82%', '60%']} />
    </div>

    {/* Composer placeholder */}
    <div class={styles.composer}>
      <Skeleton width="100%" height="44px" radius="md" />
    </div>
  </div>
)

const ConvRowSkeleton = ({ side, widths }) => (
  <div class={`${styles.row} ${side === 'user' ? styles.rowUser : styles.rowAssistant}`}>
    <div class={styles.rowEdge}>
      <Skeleton width="8px" height="8px" radius="lg" />
    </div>
    <div class={styles.rowLines}>
      {widths.map((w, i) => (
        <Skeleton key={i} width={w} height="14px" />
      ))}
    </div>
  </div>
)

export { SessionSkeleton }
