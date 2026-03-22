import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { createConversationStore, entryId } from '../../src/stores/conversation.js'

const makeEntry = (id, sequence, rowType = 'user', content = 'hello') => ({
  session_id: 'sess-1',
  sequence,
  row: { row_type: rowType, id, content },
})

describe('conversation store', () => {
  it('applies bootstrap', () => {
    const store = createConversationStore()
    store.applyBootstrap({
      rows: [makeEntry('r-1', 1), makeEntry('r-2', 2)],
      total_row_count: 10,
      has_more_before: true,
      oldest_sequence: 1,
    })
    assert.strictEqual(store.rows.value.length, 2)
    assert.strictEqual(store.totalCount.value, 10)
    assert.strictEqual(store.hasMoreBefore.value, true)
  })

  it('upserts new rows', () => {
    const store = createConversationStore()
    store.applyBootstrap({ rows: [makeEntry('r-1', 1)], total_row_count: 1 })
    store.applyRowsChanged({
      upserted: [makeEntry('r-2', 2)],
      removed_row_ids: [],
      total_row_count: 2,
    })
    assert.strictEqual(store.rows.value.length, 2)
    assert.strictEqual(store.totalCount.value, 2)
  })

  it('updates existing rows in-place by ID', () => {
    const store = createConversationStore()
    store.applyBootstrap({
      rows: [makeEntry('r-1', 1, 'assistant', 'hello')],
      total_row_count: 1,
    })
    store.applyRowsChanged({
      upserted: [makeEntry('r-1', 1, 'assistant', 'hello world')],
      removed_row_ids: [],
      total_row_count: 1,
    })
    assert.strictEqual(store.rows.value.length, 1)
    assert.strictEqual(store.rows.value[0].row.content, 'hello world')
  })

  it('removes rows by ID', () => {
    const store = createConversationStore()
    store.applyBootstrap({
      rows: [makeEntry('r-1', 1), makeEntry('r-2', 2)],
      total_row_count: 2,
    })
    store.applyRowsChanged({
      upserted: [],
      removed_row_ids: ['r-1'],
      total_row_count: 1,
    })
    assert.strictEqual(store.rows.value.length, 1)
    assert.strictEqual(entryId(store.rows.value[0]), 'r-2')
  })

  it('maintains sort order by sequence', () => {
    const store = createConversationStore()
    store.applyBootstrap({ rows: [makeEntry('r-1', 1)], total_row_count: 1 })
    store.applyRowsChanged({
      upserted: [makeEntry('r-3', 3), makeEntry('r-2', 2)],
      removed_row_ids: [],
      total_row_count: 3,
    })
    const seqs = store.rows.value.map((e) => e.sequence)
    assert.deepStrictEqual(seqs, [1, 2, 3])
  })

  it('clears store', () => {
    const store = createConversationStore()
    store.applyBootstrap({
      rows: [makeEntry('r-1', 1)],
      total_row_count: 1,
      has_more_before: true,
    })
    store.clear()
    assert.strictEqual(store.rows.value.length, 0)
    assert.strictEqual(store.totalCount.value, 0)
    assert.strictEqual(store.hasMoreBefore.value, false)
  })
})
