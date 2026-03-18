/**
 * Parse a unified diff string into the line format DiffView expects.
 * Returns an array of { kind, old_line, new_line, content }.
 *
 * Handles:
 *   - Standard unified diff (--- / +++ / @@ headers, +/- prefixed lines)
 *   - Hunk headers stripped from output (they're not useful to display)
 */
const parseDiff = (raw) => {
  if (!raw || typeof raw !== 'string') return []

  const lines = raw.split('\n')
  const result = []
  let oldLine = 0
  let newLine = 0

  for (const line of lines) {
    // Skip file headers and hunk metadata — show only content lines
    if (line.startsWith('--- ') || line.startsWith('+++ ')) continue

    if (line.startsWith('@@ ')) {
      // Parse hunk header: @@ -oldStart,oldCount +newStart,newCount @@
      const match = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
      if (match) {
        oldLine = parseInt(match[1], 10)
        newLine = parseInt(match[2], 10)
      }
      continue
    }

    if (line.startsWith('+')) {
      result.push({ kind: 'addition', old_line: null, new_line: newLine, content: line.slice(1) })
      newLine++
    } else if (line.startsWith('-')) {
      result.push({ kind: 'deletion', old_line: oldLine, new_line: null, content: line.slice(1) })
      oldLine++
    } else {
      // Context line — may be ' ' prefixed or empty (end of hunk)
      const content = line.startsWith(' ') ? line.slice(1) : line
      result.push({ kind: 'context', old_line: oldLine, new_line: newLine, content })
      oldLine++
      newLine++
    }
  }

  // Drop trailing blank context lines that add no value
  while (result.length > 0) {
    const last = result[result.length - 1]
    if (last.kind === 'context' && last.content.trim() === '') {
      result.pop()
    } else {
      break
    }
  }

  return result
}

/**
 * Extract diff text from a patch approval request.
 * Checks request.diff, request.content, and request.preview.value in order.
 */
const extractDiffText = (request) => {
  if (request.diff && typeof request.diff === 'string') return request.diff
  if (request.content && typeof request.content === 'string') return request.content
  if (request.preview?.value && typeof request.preview.value === 'string') return request.preview.value
  return null
}

export { parseDiff, extractDiffText }
