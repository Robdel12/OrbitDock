import { describe, expect, it, vi } from 'vitest'
import { decodeServerMessage, encodeClientMessage, isKnownRowType } from '../../src/api/codec.js'

describe('codec', () => {
  describe('decodeServerMessage', () => {
    it('parses a valid sessions_list message', () => {
      const raw = JSON.stringify({ type: 'sessions_list', sessions: [] })
      const result = decodeServerMessage(raw)
      expect(result).toEqual({ type: 'sessions_list', sessions: [] })
    })

    it('parses a valid session_delta message', () => {
      const raw = JSON.stringify({
        type: 'session_delta',
        session_id: 'sess-1',
        changes: { work_status: 'working' },
      })
      const result = decodeServerMessage(raw)
      expect(result.type).toBe('session_delta')
      expect(result.session_id).toBe('sess-1')
    })

    it('returns null for unknown message types', () => {
      const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
      const raw = JSON.stringify({ type: 'future_type', data: {} })
      const result = decodeServerMessage(raw)
      expect(result).toBeNull()
      expect(warnSpy).toHaveBeenCalled()
      warnSpy.mockRestore()
    })

    it('returns null for missing type field', () => {
      const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
      const raw = JSON.stringify({ sessions: [] })
      const result = decodeServerMessage(raw)
      expect(result).toBeNull()
      warnSpy.mockRestore()
    })

    it('returns null for invalid JSON', () => {
      const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
      const result = decodeServerMessage('not json')
      expect(result).toBeNull()
      warnSpy.mockRestore()
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
      expect(result.type).toBe('conversation_rows_changed')
      expect(result.total_row_count).toBe(10)
    })

    it('handles approval_requested', () => {
      const raw = JSON.stringify({
        type: 'approval_requested',
        session_id: 'sess-1',
        request: { id: 'req-1', type: 'exec' },
        approval_version: 5,
      })
      const result = decodeServerMessage(raw)
      expect(result.type).toBe('approval_requested')
      expect(result.approval_version).toBe(5)
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
        expect(isKnownRowType(type)).toBe(true)
      }
    })

    it('returns false for unknown row types', () => {
      expect(isKnownRowType('future_row')).toBe(false)
      expect(isKnownRowType('')).toBe(false)
    })
  })

  describe('encodeClientMessage', () => {
    it('encodes a subscribe_list message', () => {
      const result = encodeClientMessage({ type: 'subscribe_list' })
      expect(JSON.parse(result)).toEqual({ type: 'subscribe_list' })
    })

    it('encodes a subscribe_session message', () => {
      const msg = { type: 'subscribe_session', session_id: 'sess-1' }
      const result = encodeClientMessage(msg)
      expect(JSON.parse(result)).toEqual(msg)
    })
  })
})
