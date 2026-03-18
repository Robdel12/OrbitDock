import { useState, useEffect } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import { UsageGauge } from '../ui/usage-gauge.jsx'
import styles from './usage-summary.module.css'

const REFRESH_INTERVAL_MS = 60_000

const pickPrimaryWindow = (usage) => {
  if (!usage?.windows?.length) return null
  // Prefer the first window that has a real limit set
  return usage.windows.find((w) => w.limit > 0) ?? usage.windows[0]
}

const ProviderUsage = ({ provider, usage, error }) => {
  const colorVar = `var(--color-provider-${provider})`
  const label = provider.charAt(0).toUpperCase() + provider.slice(1)

  if (error) {
    return (
      <div class={styles.providerBlock}>
        <span class={styles.providerLabel} style={{ color: colorVar }}>{label}</span>
        <span class={styles.providerError}>{error}</span>
      </div>
    )
  }

  const window = pickPrimaryWindow(usage)
  if (!window) {
    return (
      <div class={styles.providerBlock}>
        <span class={styles.providerLabel} style={{ color: colorVar }}>{label}</span>
        <span class={styles.providerError}>No usage data</span>
      </div>
    )
  }

  return (
    <div class={styles.providerBlock}>
      <span class={styles.providerLabel} style={{ color: colorVar }}>{label}</span>
      <div class={styles.gaugeWrap}>
        <UsageGauge
          name={window.name}
          used={window.used}
          limit={window.limit}
          remaining={window.remaining}
          resetsAt={window.resets_at}
        />
      </div>
    </div>
  )
}

const UsageSummary = () => {
  const [open, setOpen] = useState(false)
  const [claudeData, setClaudeData] = useState(null)
  const [codexData, setCodexData] = useState(null)

  const fetchUsage = async () => {
    const [cu, xu] = await Promise.allSettled([
      http.get('/api/usage/claude'),
      http.get('/api/usage/codex'),
    ])
    if (cu.status === 'fulfilled') setClaudeData(cu.value)
    if (xu.status === 'fulfilled') setCodexData(xu.value)
  }

  useEffect(() => {
    fetchUsage()
    const id = setInterval(fetchUsage, REFRESH_INTERVAL_MS)
    return () => clearInterval(id)
  }, [])

  const hasAny = claudeData || codexData

  if (!hasAny) return null

  return (
    <div class={styles.panel}>
      <button
        class={styles.header}
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
      >
        <span class={styles.headerLabel}>Usage</span>
        <span class={styles.chevron} data-open={open}>›</span>
      </button>

      {open && (
        <div class={styles.body}>
          {claudeData && (
            <ProviderUsage
              provider="claude"
              usage={claudeData.usage}
              error={claudeData.error_info?.message}
            />
          )}
          {codexData && (
            <ProviderUsage
              provider="codex"
              usage={codexData.usage}
              error={codexData.error_info?.message}
            />
          )}
        </div>
      )}
    </div>
  )
}

export { UsageSummary }
