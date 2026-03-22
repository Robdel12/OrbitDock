import styles from './skeleton.module.css'

const Skeleton = ({ width, height, radius = 'md' }) => (
  <div
    class={`${styles.skeleton} ${styles[radius]}`}
    style={{
      width: width || '100%',
      height: height || '16px',
    }}
  />
)

const SkeletonRow = () => (
  <div class={styles.row}>
    <Skeleton width="60%" height="14px" />
    <Skeleton width="40%" height="12px" />
  </div>
)

const SkeletonCard = () => (
  <div class={styles.card}>
    <Skeleton width="70%" height="16px" />
    <Skeleton width="50%" height="12px" />
    <Skeleton width="30%" height="12px" />
  </div>
)

export { Skeleton, SkeletonCard, SkeletonRow }
