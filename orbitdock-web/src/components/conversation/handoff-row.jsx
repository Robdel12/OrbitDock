import { Card } from '../ui/card.jsx'
import styles from './handoff-row.module.css'

const HandoffRow = ({ entry }) => {
  const row = entry.row
  return (
    <Card edgeColor="accent" class={styles.card}>
      <div class={styles.title}>{row.title}</div>
      {row.subtitle && <div class={styles.subtitle}>{row.subtitle}</div>}
    </Card>
  )
}

export { HandoffRow }
