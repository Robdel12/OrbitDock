import { useEffect, useState } from 'preact/hooks'
import styles from './contextual-status-strip.module.css'

const useDuration = (createdAt) => {
  const [duration, setDuration] = useState(() => calcDuration(createdAt))

  useEffect(() => {
    if (!createdAt) return
    setDuration(calcDuration(createdAt))
    const id = setInterval(() => {
      setDuration(calcDuration(createdAt))
    }, 30_000)
    return () => clearInterval(id)
  }, [createdAt])

  return duration
}

const calcDuration = (createdAt) => {
  if (!createdAt) return null
  const start = new Date(createdAt).getTime()
  if (Number.isNaN(start)) return null
  const elapsed = Math.max(0, Math.floor((Date.now() - start) / 1000))
  if (elapsed < 60) return `${elapsed}s`
  const mins = Math.floor(elapsed / 60)
  if (mins < 60) return `${mins}m`
  const hrs = Math.floor(mins / 60)
  const remainMins = mins % 60
  return remainMins > 0 ? `${hrs}h ${remainMins}m` : `${hrs}h`
}

const formatTokens = (tokenUsage) => {
  if (!tokenUsage) return null
  const input = tokenUsage.input_tokens ?? tokenUsage.inputTokens ?? 0
  const output = tokenUsage.output_tokens ?? tokenUsage.outputTokens ?? 0
  const total = input + output
  if (total === 0) return null
  if (total >= 1000) return `${(total / 1000).toFixed(1)}k`
  return `${total}`
}

const formatWorkingDir = (path) => {
  if (!path) return null
  const parts = path.replace(/\\/g, '/').split('/').filter(Boolean)
  if (parts.length <= 2) return path
  return `~/${parts.slice(-2).join('/')}`
}

const ContextualStatusStrip = ({ session, tokenUsage }) => {
  const duration = useDuration(session?.created_at)

  if (!session) return null

  const hasProvider = !!session.provider
  const tokenStr = formatTokens(tokenUsage)
  const workingDir = formatWorkingDir(session.project_path || session.repository_root)

  if (!hasProvider && !tokenStr && !duration && !workingDir) {
    return null
  }

  return (
    <div class={styles.strip} role="status" aria-label="Session metadata">
      {/* Provider dot + name */}
      {hasProvider && (
        <span class={styles.item}>
          <span class={`${styles.providerDot} ${styles[`dot-${session.provider}`] || ''}`} />
          <span class={`${styles.providerName} ${styles[`provider-${session.provider}`] || ''}`}>
            {session.provider}
          </span>
        </span>
      )}

      {/* Working directory */}
      {workingDir && (
        <span class={`${styles.item} ${styles.mono}`} title={session.project_path || session.repository_root}>
          {workingDir}
        </span>
      )}

      {/* Spacer pushes right-side items */}
      <span class={styles.spacer} />

      {/* Token usage */}
      {tokenStr && (
        <span class={`${styles.item} ${styles.dimmed}`} title="Token usage">
          {tokenStr} tokens
        </span>
      )}

      {/* Duration */}
      {duration && (
        <span class={`${styles.item} ${styles.dimmed}`} title={`Started ${session.created_at}`}>
          {duration}
        </span>
      )}
    </div>
  )
}

export { ContextualStatusStrip }
