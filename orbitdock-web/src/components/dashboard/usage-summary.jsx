import { useState, useEffect } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import styles from './usage-summary.module.css'

const REFRESH_INTERVAL_MS = 60_000

const pickPrimaryWindow = (usage) => {
  if (!usage?.windows?.length) return null
  return usage.windows.find((w) => w.limit > 0) ?? usage.windows[0]
}

const getBarColor = (pct) => {
  if (pct >= 0.85) return 'negative'
  if (pct >= 0.60) return 'caution'
  return 'positive'
}

const CompactProviderPill = ({ provider, usage, error }) => {
  const window = pickPrimaryWindow(usage)
  if (!window && !error) return null

  const colorVar = `var(--color-provider-${provider})`
  const label = provider.charAt(0).toUpperCase() + provider.slice(1)

  if (error || !window) {
    return (
      <div class={styles.pill}>
        <span class={styles.providerDot} style={{ background: colorVar }} />
        <span class={styles.pillLabel}>{label}</span>
        <span class={styles.pillDash}>--</span>
      </div>
    )
  }

  const pct = window.limit > 0 ? Math.min(window.used / window.limit, 1) : 0
  const colorKey = getBarColor(pct)

  return (
    <div class={styles.pill}>
      <span class={styles.providerDot} style={{ background: colorVar }} />
      <span class={styles.pillLabel}>{label}</span>
      <span class={styles.pillPct} data-color={colorKey}>{Math.round(pct * 100)}%</span>
      <div class={styles.miniTrack}>
        <div
          class={styles.miniFill}
          data-color={colorKey}
          style={{ width: `${pct * 100}%` }}
        />
      </div>
    </div>
  )
}

const UsageSummary = () => {
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

  const claudeWindow = claudeData ? pickPrimaryWindow(claudeData.usage) : null
  const codexWindow = codexData ? pickPrimaryWindow(codexData.usage) : null
  const claudeError = claudeData?.error_info?.message
  const codexError = codexData?.error_info?.message

  // Only show if there's actual data or an error worth showing
  const showClaude = claudeWindow || claudeError
  const showCodex = codexWindow || codexError

  if (!showClaude && !showCodex) return null

  return (
    <div class={styles.usageRow}>
      {showClaude && (
        <CompactProviderPill
          provider="claude"
          usage={claudeData?.usage}
          error={claudeError}
        />
      )}
      {showCodex && (
        <CompactProviderPill
          provider="codex"
          usage={codexData?.usage}
          error={codexError}
        />
      )}
    </div>
  )
}

export { UsageSummary }
