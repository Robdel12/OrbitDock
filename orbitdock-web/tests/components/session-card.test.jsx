import assert from 'node:assert/strict'
import { describe, it, mock } from 'node:test'
import { fireEvent, render } from '@testing-library/preact'
import { SessionCard } from '../../src/components/session/session-card.jsx'

const baseSession = {
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

describe('SessionCard', () => {
  it('shows the session summary, model, and project', () => {
    const { getByText, getAllByText } = render(<SessionCard session={baseSession} onClick={() => {}} />)

    assert.ok(getAllByText('Working on the frontend').length >= 1)
    assert.ok(getByText('Opus'))
    assert.ok(getByText('project'))
  })

  it('falls back to first prompt when there is no summary', () => {
    const session = { ...baseSession, summary: null }
    const { getAllByText } = render(<SessionCard session={session} onClick={() => {}} />)

    assert.ok(getAllByText('Build a web UI').length >= 1)
  })

  it('navigates when clicked', () => {
    const handleClick = mock.fn()
    const { getByRole } = render(<SessionCard session={baseSession} onClick={handleClick} />)

    fireEvent.click(getByRole('button'))
    assert.strictEqual(handleClick.mock.callCount(), 1)
  })

  it('highlights sessions that need user attention', () => {
    const session = { ...baseSession, work_status: 'permission' }
    const { getByText } = render(<SessionCard session={session} variant="attention" onClick={() => {}} />)

    assert.ok(getByText('Wants to run a tool'))
  })
})
