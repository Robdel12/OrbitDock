/**
 * Groups consecutive tool rows (2+) into synthetic activity_group entries.
 * Single tool rows pass through ungrouped.
 * Non-tool rows are never grouped.
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
    if (entry.row?.row_type === 'tool') {
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
 * Build a human-readable summary of tool names in a group.
 * E.g. "Read, Edit, Bash + 2 more" or "Read, Write"
 */
const buildToolSummary = (buffer) => {
  const names = []
  const seen = new Set()
  for (const entry of buffer) {
    const name = entry.row?.tool_display?.summary
    if (name && !seen.has(name)) {
      seen.add(name)
      names.push(name)
    }
  }

  if (names.length === 0) return `${buffer.length} tools`

  const MAX_SHOWN = 3
  if (names.length <= MAX_SHOWN) {
    return names.join(', ')
  }
  const shown = names.slice(0, MAX_SHOWN)
  const remaining = names.length - MAX_SHOWN
  return `${shown.join(', ')} + ${remaining} more`
}

export { buildToolSummary, groupToolRuns }
