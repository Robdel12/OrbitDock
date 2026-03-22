import styles from './edge-bar.module.css'

const EdgeBar = ({ color }) => (
  <div class={styles.bar} style={{ background: color ? `var(--color-${color})` : 'var(--color-accent)' }} />
)

export { EdgeBar }
