import { describe, expect, it } from 'vitest'
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
    expect(actor.getSnapshot().value).toBe('disconnected')
    actor.stop()
  })

  it('transitions to connecting on CONNECT', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    expect(actor.getSnapshot().value).toBe('connecting')
    expect(actor.getSnapshot().context.url).toBe('ws://localhost:4000/ws')
    actor.stop()
  })

  it('transitions to connected on WS_OPEN', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    expect(actor.getSnapshot().value).toBe('connected')
    expect(actor.getSnapshot().context.attempt).toBe(0)
    actor.stop()
  })

  it('transitions to reconnecting on WS_CLOSE from connected', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    actor.send({ type: 'WS_CLOSE' })
    expect(actor.getSnapshot().value).toBe('reconnecting')
    actor.stop()
  })

  it('transitions to reconnecting on WS_ERROR from connecting', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_ERROR' })
    expect(actor.getSnapshot().value).toBe('reconnecting')
    actor.stop()
  })

  it('increments generation on each CONNECT', () => {
    const actor = createTestActor()
    expect(actor.getSnapshot().context.generation).toBe(0)
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    expect(actor.getSnapshot().context.generation).toBe(1)
    actor.stop()
  })

  it('tracks subscribed sessions', () => {
    const actor = createTestActor()
    actor.send({ type: 'CONNECT', url: 'ws://localhost:4000/ws' })
    actor.send({ type: 'WS_OPEN' })
    actor.send({ type: 'SUBSCRIBE_SESSION', sessionId: 'sess-1' })
    expect(actor.getSnapshot().context.subscribedSessions.has('sess-1')).toBe(true)
    actor.send({ type: 'UNSUBSCRIBE_SESSION', sessionId: 'sess-1' })
    expect(actor.getSnapshot().context.subscribedSessions.has('sess-1')).toBe(false)
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
    expect(actor.getSnapshot().value).toBe('disconnected')
    actor.stop()
  })
})
