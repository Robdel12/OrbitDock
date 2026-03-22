import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { render } from '@testing-library/preact'
import { ToolRow } from '../../src/components/conversation/tool-row.jsx'

const makeToolEntry = (overrides = {}) => ({
  sequence: 1,
  row: {
    row_type: 'tool',
    id: 'tool-1',
    provider: 'claude',
    family: 'shell',
    kind: 'bash',
    status: 'completed',
    title: 'Bash',
    tool_display: {
      summary: 'ls -la',
      subtitle: '/Users/rob/project',
      glyph_symbol: 'terminal',
      glyph_color: 'toolBash',
      summary_font: 'mono',
      right_meta: '0.5s',
      output_preview: 'file1.txt\nfile2.txt',
      ...overrides,
    },
  },
})

describe('ToolRow', () => {
  it('displays the command, location, timing, and output preview', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)

    assert.ok(getByText('ls -la'))
    assert.ok(getByText('/Users/rob/project'))
    assert.ok(getByText('0.5s'))
    assert.ok(getByText(/file2\.txt/))
  })

  it('absorbs timing into subtitle when told to', () => {
    const { queryByText, getByText } = render(<ToolRow entry={makeToolEntry({ subtitle_absorbs_meta: true })} />)

    assert.ok(getByText('ls -la'))
    assert.strictEqual(queryByText('0.5s'), null)
  })

  it('renders nothing when tool_display is missing', () => {
    const entry = { sequence: 1, row: { row_type: 'tool', id: 'tool-1', tool_display: null } }
    const { container } = render(<ToolRow entry={entry} />)

    assert.strictEqual(container.innerHTML, '')
  })
})
