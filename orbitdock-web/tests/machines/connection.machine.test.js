import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { createActor } from 'xstate'
import { connectionMachine } from '../../src/machines/connection.machine.js'

const createTestActor = () => {
  const actor = createActor(connectionMachine)
  actor.start()
  return actor
}

describe('connection machine', () => {
  it('starts in disconnected state', () => {
    const actor = createTestActor()
    assert.strictEqual(actor.getSnapshot().value, 'disconnected')
    actor.stop()
  })

  it('transitions to connecting on CONNECT', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    assert.strictEqual(actor.getSnapshot().value, 'connecting')
    assert.strictEqual(actor.getSnapshot().context.url, 'ws://localhost:4000/ws')
    actor.stop()
  })

  it('transitions to connected on WS_OPEN', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    assert.strictEqual(actor.getSnapshot().value, 'connected')
    assert.strictEqual(actor.getSnapshot().context.attempt, 0)
    actor.stop()
  })

  it('transitions to reconnecting on WS_CLOSE from connected', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    actor.send({ type: 'WS_CLOSE' })
    assert.strictEqual(actor.getSnapshot().value, 'reconnecting')
    actor.stop()
  })

  it('transitions to reconnecting on WS_ERROR from connecting', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_ERROR' })
    assert.strictEqual(actor.getSnapshot().value, 'reconnecting')
    actor.stop()
  })

  it('increments generation on each CONNECT', () => {
    const actor = createTestActor()
    assert.strictEqual(actor.getSnapshot().context.generation, 0)
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    assert.strictEqual(actor.getSnapshot().context.generation, 1)
    actor.stop()
  })

  it('tracks subscribed sessions', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    actor.send({ type: 'SUBSCRIBE_SESSION', sessionId: 'sess-1' })
    assert.strictEqual(actor.getSnapshot().context.subscribedSessions.has('sess-1'), true)
    actor.send({ type: 'UNSUBSCRIBE_SESSION', sessionId: 'sess-1' })
    assert.strictEqual(actor.getSnapshot().context.subscribedSessions.has('sess-1'), false)
    actor.stop()
  })

  it('transitions to disconnected on RESET from failed', () => {
    const actor = createActor(connectionMachine, {
      snapshot: connectionMachine.resolveState({
        value: 'failed',
        context: { url: '', generation: 0, attempt: 10, maxAttempts: 10, subscribedSessions: new Set() },
      }),
    })
    actor.start()
    actor.send({ type: 'RESET' })
    assert.strictEqual(actor.getSnapshot().value, 'disconnected')
    actor.stop()
  })
})
