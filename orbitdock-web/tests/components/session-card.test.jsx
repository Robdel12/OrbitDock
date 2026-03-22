import assert from 'node:assert/strict'
import { describe, it, mock } from 'node:test'
import { fireEvent, render } from '@testing-library/preact'
import { SessionCard } from '../../src/components/session/session-card.jsx'

describe('SessionCard', () => {
  const mockSession = {
    id: 'sess-1',
    provider: 'claude',
    project_path: '/Users/rob/project',
    status: 'active',
    work_status: 'working',
    model: 'claude-opus-4-6',
    last_activity_at: new Date().toISOString(),
    custom_name: null,
    summary: 'Working on the frontend',
    first_prompt: 'Build a web UI',
  }

  it('renders session name from summary', () => {
    const { getAllByText } = render(<SessionCard session={mockSession} onClick={() => {}} />)
    assert.ok(getAllByText('Working on the frontend').length >= 1)
  })

  it('falls back to first_prompt when no summary', () => {
    const session = { ...mockSession, summary: null }
    const { getAllByText } = render(<SessionCard session={session} onClick={() => {}} />)
    assert.ok(getAllByText('Build a web UI').length >= 1)
  })

  it('renders model badge with short name', () => {
    const { getByText } = render(<SessionCard session={mockSession} onClick={() => {}} />)
    assert.ok(getByText('Opus'))
  })

  it('renders project name from path', () => {
    const { getByText } = render(<SessionCard session={mockSession} onClick={() => {}} />)
    assert.ok(getByText('project'))
  })

  it('calls onClick when clicked', () => {
    const handleClick = mock.fn()
    const { getByRole } = render(<SessionCard session={mockSession} onClick={handleClick} />)
    fireEvent.click(getByRole('button'))
    assert.strictEqual(handleClick.mock.callCount(), 1)
  })

  it('renders attention variant for permission status', () => {
    const session = { ...mockSession, work_status: 'permission' }
    const { getByText } = render(<SessionCard session={session} variant="attention" onClick={() => {}} />)
    assert.ok(getByText('Wants to run a tool'))
  })
})
