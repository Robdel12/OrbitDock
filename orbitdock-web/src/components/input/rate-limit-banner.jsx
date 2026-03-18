import { useEffect, useState } from 'preact/hooks'
import styles from './rate-limit-banner.module.css'

// Formats a remaining seconds count into a human-readable string.
const formatRemaining = (seconds) => {
  if (seconds <= 0) return null
  if (seconds < 60) return `${seconds}s`
  const m = Math.ceil(seconds / 60)
  return `${m}m`
}

const RateLimitBanner = ({ info, onExpired }) => {
  // Compute the absolute expiry time once when info changes.
  const [expiry] = useState(() => {
    if (!info) return null
    return Date.now() + (info.retry_after_seconds ?? 0) * 1000
  })

  const [remaining, setRemaining] = useState(() => {
    if (!expiry) return 0
    return Math.max(0, Math.ceil((expiry - Date.now()) / 1000))
  })

  useEffect(() => {
    if (!expiry) return

    let id

    const tick = () => {
      const secs = Math.max(0, Math.ceil((expiry - Date.now()) / 1000))
      setRemaining(secs)
      if (secs <= 0) {
        clearInterval(id)
        onExpired?.()
      }
    }

    tick()
    id = setInterval(tick, 1000)
    return () => clearInterval(id)
  }, [expiry])

  if (!info) return null

  const retryLabel = formatRemaining(remaining)

  return (
    <div class={styles.banner} role="status" aria-live="polite">
      <span class={styles.icon} aria-hidden="true">⚠</span>
      <span class={styles.body}>
        <span class={styles.provider}>{info.provider}</span>
        {info.limit_type && (
          <span class={styles.limitType}>{info.limit_type.replace(/_/g, ' ')}</span>
        )}
        {info.message && <span class={styles.message}>{info.message}</span>}
      </span>
      {retryLabel && (
        <span class={styles.retry}>Retry in {retryLabel}</span>
      )}
    </div>
  )
}

export { RateLimitBanner }
