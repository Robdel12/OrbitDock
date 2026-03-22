import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { render } from '@testing-library/preact'
import { RowDispatcher } from '../../src/components/conversation/row-dispatcher.jsx'

describe('RowDispatcher', () => {
  it('renders a user row', () => {
    const entry = {
      sequence: 1,
      row: { row_type: 'user', id: 'r-1', content: 'Hello from the user' },
    }
    const { getByText } = render(<RowDispatcher entry={entry} />)
    assert.ok(getByText('Hello from the user'))
  })

  it('renders an assistant row', () => {
    const entry = {
      sequence: 2,
      row: { row_type: 'assistant', id: 'r-2', content: 'Hello from the assistant', is_streaming: false },
    }
    const { getByText } = render(<RowDispatcher entry={entry} />)
    assert.ok(getByText('Hello from the assistant'))
  })

  it('renders a system row', () => {
    const entry = {
      sequence: 3,
      row: { row_type: 'system', id: 'r-3', content: 'System message' },
    }
    const { getByText } = render(<RowDispatcher entry={entry} />)
    assert.ok(getByText('System message'))
  })

  it('returns null for unknown row types', () => {
    const entry = {
      sequence: 4,
      row: { row_type: 'future_type', id: 'r-4', content: 'Unknown' },
    }
    const { container } = render(<RowDispatcher entry={entry} />)
    assert.strictEqual(container.innerHTML, '')
  })

  it('returns null for missing row', () => {
    const entry = { sequence: 5 }
    const { container } = render(<RowDispatcher entry={entry} />)
    assert.strictEqual(container.innerHTML, '')
  })
})
