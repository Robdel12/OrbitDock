import { Card } from '../ui/card.jsx'
import styles from './plan-row.module.css'

const PlanRow = ({ entry }) => {
  const row = entry.row
  return (
    <Card edgeColor="tool-plan" class={styles.card}>
      <div class={styles.title}>{row.title}</div>
      {row.subtitle && <div class={styles.subtitle}>{row.subtitle}</div>}
    </Card>
  )
}

export { PlanRow }
