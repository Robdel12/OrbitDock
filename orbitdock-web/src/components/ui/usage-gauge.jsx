import styles from './usage-gauge.module.css'

const getBarColor = (pct) => {
  if (pct >= 0.85) return 'negative'
  if (pct >= 0.6) return 'caution'
  return 'positive'
}

const formatNumber = (n) => {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`
  return String(n)
}

const formatResetsAt = (resetsAt) => {
  if (!resetsAt) return null
  const d = new Date(resetsAt)
  if (Number.isNaN(d.getTime())) return null
  const now = Date.now()
  const diffMs = d.getTime() - now
  if (diffMs <= 0) return 'soon'
  const diffMins = Math.floor(diffMs / 60_000)
  const diffHours = Math.floor(diffMins / 60)
  if (diffHours >= 24) {
    const diffDays = Math.floor(diffHours / 24)
    return `${diffDays}d`
  }
  if (diffHours > 0) return `${diffHours}h ${diffMins % 60}m`
  return `${diffMins}m`
}

const UsageGauge = ({ name, used, limit, remaining, resetsAt }) => {
  const pct = limit > 0 ? Math.min(used / limit, 1) : 0
  const colorKey = getBarColor(pct)
  const resetsLabel = formatResetsAt(resetsAt)

  return (
    <div class={styles.gauge}>
      <div class={styles.header}>
        <span class={styles.name}>{name}</span>
        <div class={styles.meta}>
          <span class={styles.numbers}>
            {formatNumber(used)} / {formatNumber(limit)}
          </span>
          <span class={styles.pct} data-color={colorKey}>
            {Math.round(pct * 100)}%
          </span>
          {resetsLabel && <span class={styles.resets}>resets {resetsLabel}</span>}
        </div>
      </div>
      <div class={styles.track}>
        <div class={styles.fill} data-color={colorKey} style={{ width: `${pct * 100}%` }} />
      </div>
    </div>
  )
}

export { UsageGauge }
