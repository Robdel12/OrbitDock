import { Card } from '../ui/card.jsx'
import styles from './approval-row.module.css'

const ApprovalRow = ({ entry }) => {
  const row = entry.row
  return (
    <Card edgeColor="status-permission" class={styles.card}>
      <div class={styles.title}>{row.title}</div>
      {row.subtitle && <div class={styles.subtitle}>{row.subtitle}</div>}
    </Card>
  )
}

export { ApprovalRow }
