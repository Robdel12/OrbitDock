const formatDuration = (ms) => {
  if (ms == null) return null
  if (ms < 1000) return `${ms}ms`
  const seconds = ms / 1000
  if (seconds < 60) return `${seconds.toFixed(1)}s`
  const minutes = Math.floor(seconds / 60)
  const remainingSeconds = Math.floor(seconds % 60)
  return `${minutes}m ${remainingSeconds}s`
}

const formatTimestamp = (iso) => {
  if (!iso) return ''
  const date = new Date(iso)
  return date.toLocaleTimeString(undefined, {
    hour: '2-digit',
    minute: '2-digit',
  })
}

const formatTokenCount = (count) => {
  if (count == null) return ''
  if (count < 1000) return String(count)
  if (count < 1000000) return `${(count / 1000).toFixed(1)}k`
  return `${(count / 1000000).toFixed(1)}M`
}

const formatRelativeTime = (iso) => {
  if (!iso) return ''
  const then = typeof iso === 'number' ? iso * 1000 : new Date(iso).getTime()
  if (isNaN(then)) return ''
  const now = Date.now()
  const diff = now - then
  if (diff < 0) return 'just now'
  const seconds = Math.floor(diff / 1000)
  if (seconds < 60) return 'now'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h`
  const days = Math.floor(hours / 24)
  if (days < 7) return `${days}d`
  const weeks = Math.floor(days / 7)
  return `${weeks}w`
}

export { formatDuration, formatTimestamp, formatTokenCount, formatRelativeTime }
