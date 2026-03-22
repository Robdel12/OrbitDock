import assert from 'node:assert/strict'
import { describe, it, mock } from 'node:test'
import { decodeServerMessage, encodeClientMessage, isKnownRowType } from '../../src/api/codec.js'

describe('codec', () => {
  describe('decodeServerMessage', () => {
    it('parses a valid sessions_list message', () => {
      const raw = JSON.stringify({ type: 'sessions_list', sessions: [] })
      const result = decodeServerMessage(raw)
      assert.deepStrictEqual(result, { type: 'sessions_list', sessions: [] })
    })

    it('parses a valid session_delta message', () => {
      const raw = JSON.stringify({
        type: 'session_delta',
        session_id: 'sess-1',
        changes: { work_status: 'working' },
      })
      const result = decodeServerMessage(raw)
      assert.strictEqual(result.type, 'session_delta')
      assert.strictEqual(result.session_id, 'sess-1')
    })

    it('returns null for unknown message types', () => {
      const warnSpy = mock.method(console, 'warn', () => {})
      const raw = JSON.stringify({ type: 'future_type', data: {} })
      const result = decodeServerMessage(raw)
      assert.strictEqual(result, null)
      assert.ok(warnSpy.mock.callCount() > 0)
      warnSpy.mock.restore()
    })

    it('returns null for missing type field', () => {
      const warnSpy = mock.method(console, 'warn', () => {})
      const raw = JSON.stringify({ sessions: [] })
      const result = decodeServerMessage(raw)
      assert.strictEqual(result, null)
      warnSpy.mock.restore()
    })

    it('returns null for invalid JSON', () => {
      const warnSpy = mock.method(console, 'warn', () => {})
      const result = decodeServerMessage('not json')
      assert.strictEqual(result, null)
      warnSpy.mock.restore()
    })

    it('handles conversation_rows_changed', () => {
      const raw = JSON.stringify({
        type: 'conversation_rows_changed',
        session_id: 'sess-1',
        upserted: [],
        removed_row_ids: [],
        total_row_count: 10,
      })
      const result = decodeServerMessage(raw)
      assert.strictEqual(result.type, 'conversation_rows_changed')
      assert.strictEqual(result.total_row_count, 10)
    })

    it('handles approval_requested', () => {
      const raw = JSON.stringify({
        type: 'approval_requested',
        session_id: 'sess-1',
        request: { id: 'req-1', type: 'exec' },
        approval_version: 5,
      })
      const result = decodeServerMessage(raw)
      assert.strictEqual(result.type, 'approval_requested')
      assert.strictEqual(result.approval_version, 5)
    })
  })

  describe('isKnownRowType', () => {
    it('returns true for known row types', () => {
      const known = [
        'user',
        'assistant',
        'thinking',
        'system',
        'tool',
        'activity_group',
        'question',
        'approval',
        'worker',
        'plan',
        'hook',
        'handoff',
      ]
      for (const type of known) {
        assert.strictEqual(isKnownRowType(type), true)
      }
    })

    it('returns false for unknown row types', () => {
      assert.strictEqual(isKnownRowType('future_row'), false)
      assert.strictEqual(isKnownRowType(''), false)
    })
  })

  describe('encodeClientMessage', () => {
    it('encodes a subscribe_list message', () => {
      const result = encodeClientMessage({ type: 'subscribe_list' })
      assert.deepStrictEqual(JSON.parse(result), { type: 'subscribe_list' })
    })

    it('encodes a subscribe_session message', () => {
      const msg = { type: 'subscribe_session', session_id: 'sess-1' }
      const result = encodeClientMessage(msg)
      assert.deepStrictEqual(JSON.parse(result), msg)
    })
  })
})
