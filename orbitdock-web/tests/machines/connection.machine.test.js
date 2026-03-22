import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { createActor } from 'xstate'
import { connectionMachine } from '../../src/machines/connection.machine.js'

const startActor = () => {
  const actor = createActor(connectionMachine)
  actor.start()
  return actor
}

const snap = (actor) => actor.getSnapshot()

describe('WebSocket connection lifecycle', () => {
  it('establishes a connection and resets attempt count', () => {
    const actor = startActor()
    assert.strictEqual(snap(actor).value, 'disconnected')

    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    assert.strictEqual(snap(actor).value, 'connecting')
    assert.strictEqual(snap(actor).context.url, 'ws://localhost:4000/ws')

    actor.send({ type: 'WS_OPEN' })
    assert.strictEqual(snap(actor).value, 'connected')
    assert.strictEqual(snap(actor).context.attempt, 0)

    actor.stop()
  })

  it('reconnects after losing connection or hitting an error', () => {
    const actor = startActor()

    // Connection drops after being established
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    actor.send({ type: 'WS_CLOSE' })
    assert.strictEqual(snap(actor).value, 'reconnecting')
    actor.stop()

    // Error during initial connection
    const actor2 = startActor()
    actor2.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor2.send({ type: 'WS_ERROR' })
    assert.strictEqual(snap(actor2).value, 'reconnecting')
    actor2.stop()
  })

  it('tracks generation so stale sockets can be identified', () => {
    const actor = startActor()
    assert.strictEqual(snap(actor).context.generation, 0)

    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    assert.strictEqual(snap(actor).context.generation, 1)

    actor.stop()
  })

  it('tracks which sessions the user is viewing', () => {
    const actor = startActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })

    actor.send({ type: 'SUBSCRIBE_SESSION', sessionId: 'sess-1' })
    assert.strictEqual(snap(actor).context.subscribedSessions.has('sess-1'), true)

    actor.send({ type: 'UNSUBSCRIBE_SESSION', sessionId: 'sess-1' })
    assert.strictEqual(snap(actor).context.subscribedSessions.has('sess-1'), false)

    actor.stop()
  })

  it('can recover from a fully failed state', () => {
    const actor = createActor(connectionMachine, {
      snapshot: connectionMachine.resolveState({
        value: 'failed',
        context: { url: '', generation: 0, attempt: 10, maxAttempts: 10, subscribedSessions: new Set() },
      }),
    })
    actor.start()

    actor.send({ type: 'RESET' })
    assert.strictEqual(snap(actor).value, 'disconnected')

    actor.stop()
  })
})
