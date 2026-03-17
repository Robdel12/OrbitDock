import styles from './card.module.css'
import { EdgeBar } from './edge-bar.jsx'

const Card = ({ edgeColor, children, class: className, ...props }) => (
  <div class={`${styles.card} ${className || ''}`} {...props}>
    {edgeColor && <EdgeBar color={edgeColor} />}
    <div class={styles.content}>{children}</div>
  </div>
)

export { Card }
