import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { createActor } from 'xstate'
import { approvalMachine } from '../../src/machines/approval.machine.js'

const startActor = () => {
  const actor = createActor(approvalMachine)
  actor.start()
  return actor
}

const snap = (actor) => actor.getSnapshot()

describe('approval workflow', () => {
  it('user approves a tool request successfully', () => {
    const actor = startActor()

    actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-1', type: 'exec' }, approval_version: 1 })
    assert.strictEqual(snap(actor).value, 'pending')
    assert.strictEqual(snap(actor).context.request.id, 'req-1')

    actor.send({ type: 'DECIDE', decision: 'approved' })
    assert.strictEqual(snap(actor).value, 'submitting')

    actor.send({ type: 'SUBMIT_SUCCESS', approval_version: 2 })
    assert.strictEqual(snap(actor).value, 'idle')
    assert.strictEqual(snap(actor).context.request, null)
    assert.strictEqual(snap(actor).context.approvalVersion, 2)

    actor.stop()
  })

  it('user can retry after a network error', () => {
    const actor = startActor()

    actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-1', type: 'exec' }, approval_version: 1 })
    actor.send({ type: 'DECIDE', decision: 'approved' })
    actor.send({ type: 'SUBMIT_ERROR', error: 'Network error' })

    assert.strictEqual(snap(actor).value, 'pending')
    assert.strictEqual(snap(actor).context.error, 'Network error')

    actor.stop()
  })

  it('stale requests do not override the current approval', () => {
    const actor = startActor()

    actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-1', type: 'exec' }, approval_version: 5 })
    actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-2', type: 'exec' }, approval_version: 3 })

    assert.strictEqual(snap(actor).context.request.id, 'req-1')

    actor.stop()
  })

  it('server can clear a pending approval', () => {
    const actor = startActor()

    actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-1', type: 'exec' }, approval_version: 1 })
    actor.send({ type: 'CLEARED' })

    assert.strictEqual(snap(actor).value, 'idle')
    assert.strictEqual(snap(actor).context.request, null)

    actor.stop()
  })

  it('handles legacy messages without approval_version', () => {
    const actor = startActor()

    actor.send({ type: 'APPROVAL_REQUESTED', request: { id: 'req-1', type: 'exec' }, approval_version: null })
    assert.strictEqual(snap(actor).value, 'pending')

    actor.stop()
  })
})
