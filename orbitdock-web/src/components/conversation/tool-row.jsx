import { useState } from 'preact/hooks'
import { getIconName } from '../../lib/icons.js'
import { Badge } from '../ui/badge.jsx'
import { Card } from '../ui/card.jsx'
import { ToolExpanded } from './tool-expanded.jsx'
import { http } from '../../stores/connection.js'
import styles from './tool-row.module.css'

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
              <svg class={styles.chevron} width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" style={expanded ? { transform: 'rotate(90deg)' } : undefined}>
                <path d="M3.5 2L6.5 5L3.5 8" />
              </svg>
            </div>
          </div>
          {display.subtitle && (
            <div class={styles.subtitle}>{display.subtitle}</div>
          )}
        </button>
        {!expanded && display.output_preview && (
          <div class={styles.outputPreview}>{display.output_preview}</div>
        )}
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
