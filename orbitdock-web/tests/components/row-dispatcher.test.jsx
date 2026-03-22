import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { render } from '@testing-library/preact'
import { RowDispatcher } from '../../src/components/conversation/row-dispatcher.jsx'

describe('RowDispatcher', () => {
  it('renders content for known row types', () => {
    const rows = [
      { row_type: 'user', id: 'r-1', content: 'Hello from the user' },
      { row_type: 'assistant', id: 'r-2', content: 'Hello from the assistant', is_streaming: false },
      { row_type: 'system', id: 'r-3', content: 'System message' },
    ]

    for (const row of rows) {
      const { getByText } = render(<RowDispatcher entry={{ sequence: 1, row }} />)
      assert.ok(getByText(row.content), `expected '${row.row_type}' row to render its content`)
    }
  })

  it('renders nothing for unknown or missing rows', () => {
    const unknownType = render(<RowDispatcher entry={{ sequence: 1, row: { row_type: 'future_type', id: 'r-4' } }} />)
    assert.strictEqual(unknownType.container.innerHTML, '')

    const missingRow = render(<RowDispatcher entry={{ sequence: 2 }} />)
    assert.strictEqual(missingRow.container.innerHTML, '')
  })
})
