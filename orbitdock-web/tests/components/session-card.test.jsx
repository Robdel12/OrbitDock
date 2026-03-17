import { describe, it, expect, vi } from 'vitest'
import { render, fireEvent } from '@testing-library/preact'
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
    const { getByText } = render(
      <SessionCard session={mockSession} onClick={() => {}} />
    )
    expect(getByText('Working on the frontend')).toBeTruthy()
  })

  it('falls back to first_prompt when no summary', () => {
    const session = { ...mockSession, summary: null }
    const { getByText } = render(
      <SessionCard session={session} onClick={() => {}} />
    )
    expect(getByText('Build a web UI')).toBeTruthy()
  })

  it('renders provider badge', () => {
    const { getByText } = render(
      <SessionCard session={mockSession} onClick={() => {}} />
    )
    expect(getByText('claude')).toBeTruthy()
  })

  it('renders status indicator', () => {
    const { getByText } = render(
      <SessionCard session={mockSession} onClick={() => {}} />
    )
    expect(getByText('Working')).toBeTruthy()
  })

  it('calls onClick when clicked', () => {
    const handleClick = vi.fn()
    const { getByRole } = render(
      <SessionCard session={mockSession} onClick={handleClick} />
    )
    fireEvent.click(getByRole('button'))
    expect(handleClick).toHaveBeenCalledOnce()
  })

  it('renders model', () => {
    const { getByText } = render(
      <SessionCard session={mockSession} onClick={() => {}} />
    )
    expect(getByText('claude-opus-4-6')).toBeTruthy()
  })
})
