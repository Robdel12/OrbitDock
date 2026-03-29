import { useState } from 'preact/hooks'
import { CommandExecutionExpanded } from './command-execution-expanded.jsx'
import { Card } from '../ui/card.jsx'
import styles from './command-execution-row.module.css'

let semanticTone = (row) => {
  if (row.status === 'failed') return 'feedback-negative'
  if (row.status === 'declined') return 'feedback-caution'

  if (row.command_actions?.length) {
    if (row.command_actions.every((action) => action.type === 'read')) {
      return 'tool-read'
    }
    if (row.command_actions.every((action) => action.type === 'search' || action.type === 'list_files')) {
      return 'tool-search'
    }
  }

  return 'tool-bash'
}

let semanticSummary = (row) => {
  let actions = row.command_actions || []
  if (actions.length === 0) return 'Command'

  if (actions.every((action) => action.type === 'read')) {
    if (actions.length === 1) return 'Read file'
    return `Read ${actions.length} files`
  }
  if (actions.every((action) => action.type === 'search')) {
    return actions.length === 1 ? 'Search files' : 'Search across files'
  }
  if (actions.every((action) => action.type === 'list_files')) {
    return actions.length === 1 ? 'List files' : 'List file groups'
  }
  return 'Run command'
}

let isSearchRow = (row) => {
  return (row.command_actions || []).length > 0 && row.command_actions.every((action) => action.type === 'search')
}

let previewKind = (row) => row.preview?.kind || (isSearchRow(row) ? 'search_matches' : null)

let legacyPreviewLines = (row) => {
  let text = row.aggregated_output || row.live_output_preview
  if (!text) return null

  let lines = text
    .trim()
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(-2)

  return lines.length > 0 ? lines : null
}

let supportingText = (row) => {
  let actions = row.command_actions || []

  if (isSearchRow(row)) {
    let query = actions
      .map((action) => normalizeInlineText(action.query, 72))
      .find(Boolean)
    if (query) return query
  }

  let paths = Array.from(new Set(actions
    .map((action) => {
      if (action.type === 'read') return normalizeInlineText(action.name || shortenPath(action.path) || action.path, 72)
      return normalizeInlineText(shortenPath(action.path) || action.path, 72)
    })
    .filter(Boolean)))

  if (paths.length > 0) {
    return paths.length > 1 ? `${paths[0]} +${paths.length - 1} more` : paths[0]
  }

  return shortenPath(row.cwd) || normalizeInlineText(row.command, 84)
}

let collapsedPreview = (row) => {
  return row.preview?.lines || legacyPreviewLines(row)
}

let metaText = (row) => {
  let parts = []

  if (row.status === 'in_progress') parts.push('Live')
  if (row.status === 'failed') parts.push('Fail')
  if (row.status === 'declined') parts.push('Declined')

  let duration = durationLabel(row.duration_ms)
  if (duration) parts.push(duration)

  if (row.exit_code != null) parts.push(`Exit ${row.exit_code}`)

  return parts.length > 0 ? parts.join(' · ') : null
}

let durationLabel = (durationMs) => {
  if (durationMs == null) return null
  let seconds = durationMs / 1000
  return seconds >= 10 ? `${seconds.toFixed(1)}s` : `${seconds.toFixed(2)}s`
}

let shortenPath = (path) => {
  if (!path) return null
  let parts = path.split('/').filter(Boolean)
  if (parts.length <= 3) return path
  return `.../${parts.slice(-3).join('/')}`
}

let normalizeInlineText = (value, limit = 54) => {
  if (!value) return null
  let collapsed = value
    .split(/\s+/)
    .filter(Boolean)
    .join(' ')
  if (!collapsed) return null
  if (collapsed.length <= limit) return collapsed
  return `${collapsed.slice(0, limit - 1)}…`
}

let CommandExecutionRow = ({ entry }) => {
  let row = entry.row
  let [expanded, setExpanded] = useState(false)
  let summary = semanticSummary(row)
  let subtitle = supportingText(row)
  let preview = collapsedPreview(row)
  let meta = metaText(row)
  let edgeColor = semanticTone(row)
  let isFailed = row.status === 'failed' || row.status === 'declined'
  let kind = previewKind(row)

  return (
    <div class={styles.wrapper}>
      <Card edgeColor={edgeColor} class={`${styles.card} ${expanded ? styles.expanded : ''}`}>
        <button class={styles.headerButton} onClick={() => setExpanded(!expanded)}>
          <div class={styles.header}>
            <div class={styles.summaryBlock}>
              <span class={styles.summary}>{summary}</span>
              {subtitle && <span class={styles.subtitle}>{subtitle}</span>}
            </div>
            <div class={styles.headerRight}>
              {meta && <span class={`${styles.meta} ${isFailed ? styles.metaCritical : ''}`}>{meta}</span>}
              <svg
                class={styles.chevron}
                width="10"
                height="10"
                viewBox="0 0 10 10"
                fill="none"
                stroke="currentColor"
                stroke-width="1.5"
                stroke-linecap="round"
                stroke-linejoin="round"
                style={expanded ? { transform: 'rotate(90deg)' } : undefined}
              >
                <path d="M3.5 2L6.5 5L3.5 8" />
              </svg>
            </div>
          </div>
        </button>

        {!expanded && preview && (
          <div class={`${styles.outputPreview} ${isFailed ? styles.outputPreviewFailed : ''}`}>
            {preview.map((line, index) => (
              <div
                key={`${kind || 'preview'}-${index}`}
                class={`${styles.previewLine} ${kind === 'status' ? styles.previewLineStatus : ''}`}
              >
                {kind === 'search_matches' && (
                  <span class={styles.previewPrefix}>{index === 0 ? '>' : '·'}</span>
                )}
                {kind !== 'search_matches' && kind !== 'status' && (
                  <span class={styles.previewBullet} aria-hidden="true" />
                )}
                <span
                  class={`${styles.previewText} ${
                    kind === 'diff' && line.startsWith('+') && !line.startsWith('+++') ? styles.previewTextAdd : ''
                  } ${
                    kind === 'diff' && line.startsWith('-') && !line.startsWith('---') ? styles.previewTextRemove : ''
                  }`}
                >
                  {line}
                </span>
              </div>
            ))}
          </div>
        )}

        {expanded && (
          <CommandExecutionExpanded sessionId={entry.session_id} rowId={row.id} row={row} />
        )}
      </Card>
    </div>
  )
}

export { CommandExecutionRow }
