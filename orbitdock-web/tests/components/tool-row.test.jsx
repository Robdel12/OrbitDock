import { render } from '@testing-library/preact'
import { describe, expect, it } from 'vitest'
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
    expect(getByText('ls -la')).toBeTruthy()
  })

  it('renders subtitle', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    expect(getByText('/Users/rob/project')).toBeTruthy()
  })

  it('renders right_meta badge', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    expect(getByText('0.5s')).toBeTruthy()
  })

  it('hides right_meta when subtitle_absorbs_meta is true', () => {
    const { queryByText } = render(<ToolRow entry={makeToolEntry({ subtitle_absorbs_meta: true })} />)
    expect(queryByText('0.5s')).toBeNull()
  })

  it('renders inline preview for bash output', () => {
    const { getByText } = render(<ToolRow entry={makeToolEntry()} />)
    // InlinePreview shows the last line of bash output
    expect(getByText(/file2\.txt/)).toBeTruthy()
  })

  it('returns null when tool_display is missing', () => {
    const entry = {
      sequence: 1,
      row: { row_type: 'tool', id: 'tool-1', tool_display: null },
    }
    const { container } = render(<ToolRow entry={entry} />)
    expect(container.innerHTML).toBe('')
  })
})
