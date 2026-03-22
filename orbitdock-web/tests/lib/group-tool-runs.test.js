import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { buildToolSummary, groupToolRuns } from '../../src/lib/group-tool-runs.js'

const makeRow = (id, rowType = 'user', toolSummary = null) => ({
  session_id: 'sess-1',
  sequence: Number(id.replace(/\D/g, '')),
  row: {
    id,
    row_type: rowType,
    ...(toolSummary ? { tool_display: { summary: toolSummary } } : {}),
  },
})

describe('groupToolRuns', () => {
  it('passes non-tool rows through unchanged', () => {
    const rows = [makeRow('1', 'user'), makeRow('2', 'assistant')]
    const result = groupToolRuns(rows)
    assert.strictEqual(result.length, 2)
    assert.strictEqual(result[0].row.row_type, 'user')
    assert.strictEqual(result[1].row.row_type, 'assistant')
  })

  it('does not group a single tool row', () => {
    const rows = [makeRow('1', 'user'), makeRow('2', 'tool', 'Read'), makeRow('3', 'assistant')]
    const result = groupToolRuns(rows)
    assert.strictEqual(result.length, 3)
    assert.strictEqual(result[1].row.row_type, 'tool')
  })

  it('groups 2+ consecutive tool rows into an activity_group', () => {
    const rows = [
      makeRow('1', 'user'),
      makeRow('2', 'tool', 'Read'),
      makeRow('3', 'tool', 'Edit'),
      makeRow('4', 'assistant'),
    ]
    const result = groupToolRuns(rows)
    assert.strictEqual(result.length, 3)
    assert.strictEqual(result[1].row.row_type, 'activity_group')
    assert.strictEqual(result[1].row.tool_count, 2)
    assert.strictEqual(result[1].row.children.length, 2)
    assert.strictEqual(result[1].row.id, 'group:2')
  })

  it('creates separate groups for non-adjacent tool runs', () => {
    const rows = [
      makeRow('1', 'tool', 'Read'),
      makeRow('2', 'tool', 'Edit'),
      makeRow('3', 'assistant'),
      makeRow('4', 'tool', 'Bash'),
      makeRow('5', 'tool', 'Write'),
    ]
    const result = groupToolRuns(rows)
    assert.strictEqual(result.length, 3)
    assert.strictEqual(result[0].row.row_type, 'activity_group')
    assert.strictEqual(result[2].row.row_type, 'activity_group')
  })

  it('handles empty input', () => {
    assert.deepStrictEqual(groupToolRuns([]), [])
  })
})

describe('buildToolSummary', () => {
  it('joins unique tool names with commas', () => {
    const buffer = [makeRow('1', 'tool', 'Read'), makeRow('2', 'tool', 'Edit')]
    assert.strictEqual(buildToolSummary(buffer), 'Read, Edit')
  })

  it('deduplicates tool names', () => {
    const buffer = [makeRow('1', 'tool', 'Read'), makeRow('2', 'tool', 'Read'), makeRow('3', 'tool', 'Edit')]
    assert.strictEqual(buildToolSummary(buffer), 'Read, Edit')
  })

  it('truncates after 3 unique names with a count', () => {
    const buffer = [
      makeRow('1', 'tool', 'Read'),
      makeRow('2', 'tool', 'Edit'),
      makeRow('3', 'tool', 'Bash'),
      makeRow('4', 'tool', 'Write'),
    ]
    assert.strictEqual(buildToolSummary(buffer), 'Read, Edit, Bash + 1 more')
  })

  it('falls back to count when no tool names exist', () => {
    const buffer = [makeRow('1', 'tool'), makeRow('2', 'tool')]
    assert.strictEqual(buildToolSummary(buffer), '2 tools')
  })
})
