import assert from 'node:assert/strict'
import { afterEach, describe, it } from 'node:test'
import { clearDraft, loadDraft, saveDraft } from '../../src/lib/draft-store.js'

afterEach(() => {
  localStorage.clear()
})

describe('draft-store', () => {
  it('saves and loads a draft by session id', () => {
    saveDraft('sess-1', 'hello world')
    assert.strictEqual(loadDraft('sess-1'), 'hello world')
  })

  it('removes the draft when saving empty text', () => {
    saveDraft('sess-1', 'something')
    saveDraft('sess-1', '   ')
    assert.strictEqual(loadDraft('sess-1'), '')
  })

  it('clearDraft removes a stored draft', () => {
    saveDraft('sess-1', 'draft text')
    clearDraft('sess-1')
    assert.strictEqual(loadDraft('sess-1'), '')
  })

  it('returns empty string for unknown session', () => {
    assert.strictEqual(loadDraft('unknown'), '')
  })

  it('is a no-op when session id is falsy', () => {
    saveDraft(null, 'text')
    saveDraft(undefined, 'text')
    assert.strictEqual(loadDraft(null), '')
    assert.strictEqual(loadDraft(undefined), '')
  })

  it('isolates drafts by session id', () => {
    saveDraft('sess-1', 'alpha')
    saveDraft('sess-2', 'beta')
    assert.strictEqual(loadDraft('sess-1'), 'alpha')
    assert.strictEqual(loadDraft('sess-2'), 'beta')
  })
})
