import { useState } from 'preact/hooks'
import { Card } from '../ui/card.jsx'
import { CommandExecutionExpanded } from './command-execution-expanded.jsx'
import styles from './command-execution-row.module.css'

const semanticTone = (row) => {
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

const semanticSummary = (row) => {
  const actions = row.command_actions || []
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

const isSearchRow = (row) => {
  return (row.command_actions || []).length > 0 && row.command_actions.every((action) => action.type === 'search')
}

const previewKind = (row) => row.preview?.kind || (isSearchRow(row) ? 'search_matches' : null)

const legacyPreviewLines = (row) => {
  const text = row.aggregated_output || row.live_output_preview
  if (!text) return null

  const lines = text
    .trim()
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .slice(-2)

  return lines.length > 0 ? lines : null
}

const supportingText = (row) => {
  const actions = row.command_actions || []

  if (isSearchRow(row)) {
    const query = actions.map((action) => normalizeInlineText(action.query, 72)).find(Boolean)
    if (query) return query
  }

  const paths = Array.from(
    new Set(
      actions
        .map((action) => {
          if (action.type === 'read')
            return normalizeInlineText(action.name || shortenPath(action.path) || action.path, 72)
          return normalizeInlineText(shortenPath(action.path) || action.path, 72)
        })
        .filter(Boolean),
    ),
  )

  if (paths.length > 0) {
    return paths.length > 1 ? `${paths[0]} +${paths.length - 1} more` : paths[0]
  }

  return shortenPath(row.cwd) || normalizeInlineText(row.command, 84)
}

const collapsedPreview = (row) => {
  return row.preview?.lines || legacyPreviewLines(row)
}

const metaText = (row) => {
  const parts = []

  if (row.status === 'in_progress') parts.push('Live')
  if (row.status === 'failed') parts.push('Fail')
  if (row.status === 'declined') parts.push('Declined')

  const duration = durationLabel(row.duration_ms)
  if (duration) parts.push(duration)

  if (row.exit_code != null) parts.push(`Exit ${row.exit_code}`)

  return parts.length > 0 ? parts.join(' · ') : null
}

const durationLabel = (durationMs) => {
  if (durationMs == null) return null
  const seconds = durationMs / 1000
  return seconds >= 10 ? `${seconds.toFixed(1)}s` : `${seconds.toFixed(2)}s`
}

const shortenPath = (path) => {
  if (!path) return null
  const parts = path.split('/').filter(Boolean)
  if (parts.length <= 3) return path
  return `.../${parts.slice(-3).join('/')}`
}

const normalizeInlineText = (value, limit = 54) => {
  if (!value) return null
  const collapsed = value.split(/\s+/).filter(Boolean).join(' ')
  if (!collapsed) return null
  if (collapsed.length <= limit) return collapsed
  return `${collapsed.slice(0, limit - 1)}…`
}

const CommandExecutionRow = ({ entry }) => {
  const row = entry.row
  const [expanded, setExpanded] = useState(false)
  const summary = semanticSummary(row)
  const subtitle = supportingText(row)
  const preview = collapsedPreview(row)
  const meta = metaText(row)
  const edgeColor = semanticTone(row)
  const isFailed = row.status === 'failed' || row.status === 'declined'
  const kind = previewKind(row)

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
                {kind === 'search_matches' && <span class={styles.previewPrefix}>{index === 0 ? '>' : '·'}</span>}
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

        {expanded && <CommandExecutionExpanded sessionId={entry.session_id} rowId={row.id} row={row} />}
      </Card>
    </div>
  )
}

export { CommandExecutionRow }
