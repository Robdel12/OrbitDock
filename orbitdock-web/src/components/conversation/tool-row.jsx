import { useState } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import { Badge } from '../ui/badge.jsx'
import { Card } from '../ui/card.jsx'
import { ToolExpanded } from './tool-expanded.jsx'
import styles from './tool-row.module.css'

// ---------------------------------------------------------------------------
// Inline preview — richer collapsed state for different tool types
// ---------------------------------------------------------------------------

const InlinePreview = ({ display }) => {
  // Diff preview: show first line of diff in mono with +/- coloring
  if (display.diff_preview && typeof display.diff_preview === 'string') {
    const firstLine = display.diff_preview.trim().split('\n')[0] || ''
    const isDeletion = firstLine.startsWith('-')
    const isAddition = firstLine.startsWith('+')
    return (
      <div class={`${styles.inlinePreview} ${styles.diffPreview}`}>
        <span class={`${styles.diffLine} ${isAddition ? styles.diffAdd : ''} ${isDeletion ? styles.diffRemove : ''}`}>
          {firstLine}
        </span>
      </div>
    )
  }

  // Todo tool: show progress if available in output_preview
  if (display.glyph_color === 'toolTodo' && display.output_preview) {
    const match = display.output_preview.match(/(\d+)\s*\/\s*(\d+)/)
    if (match) {
      const done = parseInt(match[1], 10)
      const total = parseInt(match[2], 10)
      const pct = total > 0 ? Math.round((done / total) * 100) : 0
      return (
        <div class={`${styles.inlinePreview} ${styles.todoPreview}`}>
          <svg
            width="10"
            height="10"
            viewBox="0 0 10 10"
            fill="none"
            stroke="currentColor"
            stroke-width="1.2"
            stroke-linecap="round"
          >
            <rect x="1" y="1" width="8" height="8" rx="1" />
            <path d="M3 5l1.5 1.5L7 4" />
          </svg>
          <span>
            {done}/{total} done
          </span>
          <span class={styles.todoBar}>
            <span class={styles.todoBarFill} style={{ width: `${pct}%` }} />
          </span>
        </div>
      )
    }
  }

  // Bash tool: show pulsing dot + last output line
  if (display.glyph_color === 'toolBash' && display.output_preview) {
    const lastLine = display.output_preview.trim().split('\n').pop() || ''
    return (
      <div class={`${styles.inlinePreview} ${styles.bashPreview}`}>
        <span class={styles.bashDot} />
        <span class={styles.bashLine}>{lastLine}</span>
      </div>
    )
  }

  // Fallback: plain output preview
  if (display.output_preview) {
    return <div class={styles.outputPreview}>{display.output_preview}</div>
  }

  return null
}

const GLYPH_COLOR_MAP = {
  toolBash: 'tool-bash',
  toolRead: 'tool-read',
  toolWrite: 'tool-write',
  toolSearch: 'tool-search',
  toolTask: 'tool-task',
  toolQuestion: 'tool-question',
  toolMcp: 'tool-mcp',
  toolSkill: 'tool-skill',
  toolPlan: 'tool-plan',
  toolTodo: 'tool-todo',
}

const ToolRow = ({ entry }) => {
  const row = entry.row
  const display = row.tool_display
  if (!display) return null

  const [expanded, setExpanded] = useState(false)
  const edgeColor = GLYPH_COLOR_MAP[display.glyph_color] || 'accent'
  const fontClass = display.summary_font === 'mono' ? styles.mono : ''

  return (
    <div class={styles.wrapper}>
      <Card edgeColor={edgeColor} class={`${styles.card} ${expanded ? styles.expanded : ''}`}>
        <button class={styles.headerButton} onClick={() => setExpanded(!expanded)}>
          <div class={styles.header}>
            <span class={`${styles.summary} ${fontClass}`}>{display.summary}</span>
            <div class={styles.headerRight}>
              {display.right_meta && !display.subtitle_absorbs_meta && (
                <Badge variant="tool">{display.right_meta}</Badge>
              )}
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
          {display.subtitle && <div class={styles.subtitle}>{display.subtitle}</div>}
        </button>
        {!expanded && <InlinePreview display={display} />}
        {expanded && (
          <ToolExpanded
            sessionId={entry.session_id}
            rowId={row.id}
            http={http}
            outputPreview={display.output_preview}
            diffPreview={display.diff_preview}
          />
        )}
      </Card>
    </div>
  )
}

export { ToolRow }
