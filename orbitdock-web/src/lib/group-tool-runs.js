/**
 * Groups consecutive activity rows (2+) into synthetic activity_group entries.
 * Single activity rows pass through ungrouped.
 * Non-activity rows are never grouped.
 */
let groupToolRuns = (rows) => {
  let result = []
  let buffer = []

  let flushBuffer = () => {
    if (buffer.length >= 2) {
      let first = buffer[0]
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

  for (let entry of rows) {
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
 * E.g. "Read file, Search files, Run command + 2 more"
 */
let buildToolSummary = (buffer) => {
  let names = []
  let seen = new Set()
  for (let entry of buffer) {
    let name = activitySummary(entry)
    if (name && !seen.has(name)) {
      seen.add(name)
      names.push(name)
    }
  }

  if (names.length === 0) return `${buffer.length} actions`

  let MAX_SHOWN = 3
  if (names.length <= MAX_SHOWN) {
    return names.join(', ')
  }
  let shown = names.slice(0, MAX_SHOWN)
  let remaining = names.length - MAX_SHOWN
  return `${shown.join(', ')} + ${remaining} more`
}

let isGroupableActivity = (entry) => {
  let rowType = entry.row?.row_type
  return rowType === 'tool' || rowType === 'command_execution'
}

let activitySummary = (entry) => {
  let row = entry.row
  if (!row) return null

  if (row.row_type === 'tool') {
    return row.tool_display?.summary || row.title || null
  }

  if (row.row_type !== 'command_execution') {
    return null
  }

  let actions = row.command_actions || []
  if (actions.length === 0) return 'Run command'

  if (actions.every((action) => action.type === 'read')) {
    return actions.length === 1 ? 'Read file' : `Read ${actions.length} files`
  }
  if (actions.every((action) => action.type === 'search')) {
    return actions.length === 1 ? 'Search files' : 'Search across files'
  }
  if (actions.every((action) => action.type === 'list_files')) {
    return 'List files'
  }

  return 'Run command'
}

export { buildToolSummary, groupToolRuns }
