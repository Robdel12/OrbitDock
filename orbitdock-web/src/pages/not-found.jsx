import { Link } from 'wouter-preact'
import styles from './not-found.module.css'

const NotFoundPage = () => (
  <div class={styles.page}>
    <h1 class={styles.code}>404</h1>
    <p class={styles.message}>Page not found</p>
    <Link href="/" class={styles.link}>Back to Sessions</Link>
  </div>
)

export { NotFoundPage }
