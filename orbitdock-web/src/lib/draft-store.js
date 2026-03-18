const DRAFT_PREFIX = 'orbitdock:draft:'

const saveDraft = (sessionId, text) => {
  if (!sessionId) return
  const key = DRAFT_PREFIX + sessionId
  if (text.trim()) {
    localStorage.setItem(key, text)
  } else {
    localStorage.removeItem(key)
  }
}

const loadDraft = (sessionId) => {
  if (!sessionId) return ''
  return localStorage.getItem(DRAFT_PREFIX + sessionId) || ''
}

const clearDraft = (sessionId) => {
  if (!sessionId) return
  localStorage.removeItem(DRAFT_PREFIX + sessionId)
}

export { saveDraft, loadDraft, clearDraft }
