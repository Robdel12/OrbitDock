import styles from './spinner.module.css'

const Spinner = ({ size = 'md' }) => (
  <div class={`${styles.spinner} ${styles[size]}`} role="status" aria-label="Loading" />
)

export { Spinner }
