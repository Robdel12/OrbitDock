import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
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
    assert.strictEqual(actor.getSnapshot().value, 'idle')
    actor.stop()
  })

  it('transitions to pending on APPROVAL_REQUESTED with newer version', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 1,
    })
    assert.strictEqual(actor.getSnapshot().value, 'pending')
    assert.strictEqual(actor.getSnapshot().context.request.id, 'req-1')
    assert.strictEqual(actor.getSnapshot().context.approvalVersion, 1)
    actor.stop()
  })

  it('rejects stale approval requests', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 5,
    })
    assert.strictEqual(actor.getSnapshot().value, 'pending')
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-2', type: 'exec' },
      approval_version: 3,
    })
    assert.strictEqual(actor.getSnapshot().context.request.id, 'req-1')
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
    assert.strictEqual(actor.getSnapshot().value, 'submitting')
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
    assert.strictEqual(actor.getSnapshot().value, 'idle')
    assert.strictEqual(actor.getSnapshot().context.request, null)
    assert.strictEqual(actor.getSnapshot().context.approvalVersion, 2)
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
    assert.strictEqual(actor.getSnapshot().value, 'pending')
    assert.strictEqual(actor.getSnapshot().context.error, 'Network error')
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
    assert.strictEqual(actor.getSnapshot().value, 'idle')
    assert.strictEqual(actor.getSnapshot().context.request, null)
    actor.stop()
  })

  it('accepts null approval_version (backwards compat)', () => {
    const actor = createTestActor()
    actor.send({
      type: 'APPROVAL_REQUESTED',
      request: { id: 'req-1', type: 'exec' },
      approval_version: null,
    })
    assert.strictEqual(actor.getSnapshot().value, 'pending')
    actor.stop()
  })
})
