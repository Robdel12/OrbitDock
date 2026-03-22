import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { render } from '@testing-library/preact'
import { ToolRow } from '../../src/components/conversation/tool-row.jsx'

describe('ToolRow', () => {
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

  it('renders tool display summary', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    assert.ok(getByText('ls -la'))
  })

  it('renders subtitle', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    assert.ok(getByText('/Users/rob/project'))
  })

  it('renders right_meta badge', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    assert.ok(getByText('0.5s'))
  })

  it('hides right_meta when subtitle_absorbs_meta is true', () => {
    const { queryByText } = render(<ToolRow entry={makeToolEntry({ subtitle_absorbs_meta: true })} />)
    assert.strictEqual(queryByText('0.5s'), null)
  })

  it('renders inline preview for bash output', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    assert.ok(getByText(/file2\.txt/))
  })

  it('returns null when tool_display is missing', () => {
    const entry = {
      sequence: 1,
      row: { row_type: 'tool', id: 'tool-1', tool_display: null },
    }
    const { container } = render(<ToolRow entry={entry} />)
    assert.strictEqual(container.innerHTML, '')
  })
})
