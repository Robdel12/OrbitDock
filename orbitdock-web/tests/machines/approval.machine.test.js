import { describe, it, expect } from 'vitest'
import { createActor } from 'xstate'
import { approvalMachine } from '../../src/machines/approval.machine.js'

const createTestActor = () => {
  const actor = createActor(approvalMachine)
  actor.start()
  return actor
}

describe('approval machine', () => {
  it('starts in idle state', () => {
    const actor = createTestActor()
    expect(actor.getSnapshot().value).toBe('idle')
    actor.stop()
  })

  it('transitions to pending on APPROVAL_REQUESTED with newer version', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 1,
    })
    expect(actor.getSnapshot().value).toBe('pending')
    expect(actor.getSnapshot().context.request.id).toBe('req-1')
    expect(actor.getSnapshot().context.approvalVersion).toBe(1)
    actor.stop()
  })

  it('rejects stale approval requests', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 5,
    })
    expect(actor.getSnapshot().value).toBe('pending')
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-2', type: 'exec' },
      approval_version: 3,
    })
    expect(actor.getSnapshot().context.request.id).toBe('req-1')
    actor.stop()
  })

  it('transitions to submitting on DECIDE', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 1,
    })
    actor.send({ type: 'DECIDE', decision: 'approved' })
    expect(actor.getSnapshot().value).toBe('submitting')
    actor.stop()
  })

  it('transitions to idle on SUBMIT_SUCCESS', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 1,
    })
    actor.send({ type: 'DECIDE', decision: 'approved' })
    actor.send({ type: 'SUBMIT_SUCCESS', approval_version: 2 })
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.request).toBeNull()
    expect(actor.getSnapshot().context.approvalVersion).toBe(2)
    actor.stop()
  })

  it('transitions back to pending on SUBMIT_ERROR', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 1,
    })
    actor.send({ type: 'DECIDE', decision: 'approved' })
    actor.send({ type: 'SUBMIT_ERROR', error: 'Network error' })
    expect(actor.getSnapshot().value).toBe('pending')
    expect(actor.getSnapshot().context.error).toBe('Network error')
    actor.stop()
  })

  it('clears request on CLEARED', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 1,
    })
    actor.send({ type: 'CLEARED' })
    expect(actor.getSnapshot().value).toBe('idle')
    expect(actor.getSnapshot().context.request).toBeNull()
    actor.stop()
  })

  it('accepts null approval_version (backwards compat)', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: null,
    })
    expect(actor.getSnapshot().value).toBe('pending')
    actor.stop()
  })
})
