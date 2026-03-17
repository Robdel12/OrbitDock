import styles from './status-indicator.module.css'

const STATUS_LABELS = {
  working: 'Working',
  waiting: 'Waiting',
  permission: 'Needs Approval',
  question: 'Question',
  reply: 'Awaiting Reply',
  ended: 'Ended',
}

const StatusIndicator = ({ workStatus }) => {
  const label = STATUS_LABELS[workStatus] || workStatus
  return <span class={`${styles.indicator} ${styles[workStatus] || ''}`}>{label}</span>
}

export { StatusIndicator }
