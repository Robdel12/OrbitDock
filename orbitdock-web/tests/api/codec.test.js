import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { decodeServerMessage, encodeClientMessage, isKnownRowType } from '../../src/api/codec.js'

describe('server message decoding', () => {
  it('passes through valid messages with all fields intact', () => {
    const sessionDelta = JSON.stringify({
      type: 'session_delta',
      session_id: 'sess-1',
      changes: { work_status: 'working' },
    })
    const rowsChanged = JSON.stringify({
      type: 'conversation_rows_changed',
      session_id: 'sess-1',
      upserted: [],
      removed_row_ids: [],
      total_row_count: 10,
    })
    const approval = JSON.stringify({
      type: 'approval_requested',
      session_id: 'sess-1',
      request: { id: 'req-1', type: 'exec' },
      approval_version: 5,
    })

    const delta = decodeServerMessage(sessionDelta)
    assert.strictEqual(delta.type, 'session_delta')
    assert.strictEqual(delta.session_id, 'sess-1')

    const rows = decodeServerMessage(rowsChanged)
    assert.strictEqual(rows.total_row_count, 10)

    const req = decodeServerMessage(approval)
    assert.strictEqual(req.approval_version, 5)
  })

  it('safely ignores malformed or unknown input', () => {
    assert.strictEqual(decodeServerMessage('not json'), null)
    assert.strictEqual(decodeServerMessage(JSON.stringify({ sessions: [] })), null)
    assert.strictEqual(decodeServerMessage(JSON.stringify({ type: 'future_type', data: {} })), null)
  })
})

describe('client message encoding', () => {
  it('round-trips through JSON', () => {
    const msg = { type: 'subscribe_session', session_id: 'sess-1' }
    assert.deepStrictEqual(JSON.parse(encodeClientMessage(msg)), msg)
  })
})

describe('row type classification', () => {
  it('recognizes all supported row types', () => {
    for (const type of ['user', 'assistant', 'tool', 'system', 'approval']) {
      assert.strictEqual(isKnownRowType(type), true, `expected '${type}' to be known`)
    }
  })

  it('rejects unknown types gracefully', () => {
    assert.strictEqual(isKnownRowType('future_row'), false)
    assert.strictEqual(isKnownRowType(''), false)
  })
})
