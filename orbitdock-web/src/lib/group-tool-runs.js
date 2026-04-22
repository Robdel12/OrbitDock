/**
 * Groups consecutive activity rows (2+) into synthetic activity_group entries.
 * Single activity rows pass through ungrouped.
 * Non-activity rows are never grouped.
 */
const groupToolRuns = (rows) => {
  const result = []
  const buffer = []

  const flushBuffer = () => {
    if (buffer.length >= 2) {
      const first = buffer[0]
      result.push({
        sequence: first.sequence,
        session_id: first.session_id,
        row: {
          id: `group:${first.row.id}`,
          row_type: 'activity_group',
          title: buildToolSummary(buffer),
          tool_count: buffer.length,
          children: [...buffer],
        },
      })
    } else if (buffer.length === 1) {
      result.push(buffer[0])
    }
    buffer.length = 0
  }

  for (const entry of rows) {
    if (isGroupableActivity(entry)) {
      buffer.push(entry)
    } else {
      flushBuffer()
      result.push(entry)
    }
  }
  flushBuffer()

  return result
}

/**
 * Build a human-readable summary of grouped activity names.
 * E.g. "Read, Search, Bash + 2 more"
 */
const buildToolSummary = (buffer) => {
  const names = []
  const seen = new Set()
  for (const entry of buffer) {
    const name = activitySummary(entry)
    if (name && !seen.has(name)) {
      seen.add(name)
      names.push(name)
    }
  }

  if (names.length === 0) return `${buffer.length} actions`

  const MAX_SHOWN = 3
  if (names.length <= MAX_SHOWN) {
    return names.join(', ')
  }
  const shown = names.slice(0, MAX_SHOWN)
  const remaining = names.length - MAX_SHOWN
  return `${shown.join(', ')} + ${remaining} more`
}

const isGroupableActivity = (entry) => {
  const rowType = entry.row?.row_type
  return rowType === 'tool'
}

const activitySummary = (entry) => {
  const row = entry.row
  if (!row) return null

  return row.row_type === 'tool' ? row.tool_display?.summary || row.title || null : null
}

export { buildToolSummary, groupToolRuns }
