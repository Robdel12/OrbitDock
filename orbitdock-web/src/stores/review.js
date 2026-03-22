import { computed, signal } from '@preact/signals'
import { http } from './connection.js'

// ---------------------------------------------------------------------------
// State signals
// ---------------------------------------------------------------------------

/** Map<commentId, comment> — flat lookup for all loaded comments */
const _commentsById = signal(new Map())

/** Current session whose comments are loaded */
const _sessionId = signal(null)

/** Whether the review panel is open */
const reviewPanelOpen = signal(false)

/** Currently selected file path in the navigator */
const activeFile = signal(null)

/** The raw turn diff data: { files: [...], raw_diff: '...' } */
const diffData = signal(null)

/** True while diff is loading */
const diffLoading = signal(false)

/** Error string if diff or comment load failed */
const reviewError = signal(null)

// ---------------------------------------------------------------------------
// Derived
// ---------------------------------------------------------------------------

/**
 * Comments grouped by file path then by line number.
 * Shape: Map<filePath, Map<lineNumber, comment[]>>
 */
const reviewComments = computed(() => {
  const grouped = new Map()
  for (const comment of _commentsById.value.values()) {
    const file = comment.file_path || ''
    if (!grouped.has(file)) grouped.set(file, new Map())
    const byLine = grouped.get(file)
    const line = comment.line_number ?? 0
    if (!byLine.has(line)) byLine.set(line, [])
    byLine.get(line).push(comment)
  }
  return grouped
})

// ---------------------------------------------------------------------------
// Comment mutations
// ---------------------------------------------------------------------------

const addComment = (comment) => {
  const next = new Map(_commentsById.value)
  next.set(comment.id, comment)
  _commentsById.value = next
}

const updateComment = (comment) => {
  const next = new Map(_commentsById.value)
  next.set(comment.id, comment)
  _commentsById.value = next
}

const removeComment = (commentId) => {
  const next = new Map(_commentsById.value)
  next.delete(commentId)
  _commentsById.value = next
}

// ---------------------------------------------------------------------------
// Data loading
// ---------------------------------------------------------------------------

const loadComments = async (sessionId) => {
  try {
    const data = await http.get(`/api/sessions/${sessionId}/review-comments`)
    const next = new Map()
    const list = data.comments || data || []
    for (const c of list) next.set(c.id, c)
    _commentsById.value = next
    _sessionId.value = sessionId
  } catch (err) {
    console.warn('[review] failed to load comments:', err.message)
    reviewError.value = err.message
  }
}

const loadDiff = async (sessionId) => {
  if (diffLoading.value) return
  diffLoading.value = true
  reviewError.value = null
  try {
    const data = await http.get(`/api/sessions/${sessionId}/turn-diff`)
    diffData.value = data
  } catch (err) {
    console.warn('[review] failed to load diff:', err.message)
    reviewError.value = err.message
  } finally {
    diffLoading.value = false
  }
}

/**
 * Open the review panel and load data for the given session.
 * Idempotent — will not re-fetch if already loaded for the same session.
 */
const openReviewPanel = async (sessionId) => {
  reviewPanelOpen.value = true
  const alreadyLoaded = _sessionId.value === sessionId

  if (!alreadyLoaded || !diffData.value) {
    await Promise.all([loadDiff(sessionId), loadComments(sessionId)])
    _sessionId.value = sessionId
  }
}

const closeReviewPanel = () => {
  reviewPanelOpen.value = false
}

/** Reset all review state — call when navigating away from a session */
const resetReview = () => {
  _commentsById.value = new Map()
  _sessionId.value = null
  reviewPanelOpen.value = false
  activeFile.value = null
  diffData.value = null
  diffLoading.value = false
  reviewError.value = null
}

// ---------------------------------------------------------------------------
// WS event handlers — called from the conversation handler in session.jsx
// ---------------------------------------------------------------------------

const handleReviewWsEvent = (msg) => {
  switch (msg.type) {
    case 'review_comment_created':
      if (msg.comment) addComment(msg.comment)
      break
    case 'review_comment_updated':
      if (msg.comment) updateComment(msg.comment)
      break
    case 'review_comment_deleted':
      if (msg.comment_id) removeComment(msg.comment_id)
      break
    case 'review_comments_list': {
      const next = new Map()
      const list = msg.comments || []
      for (const c of list) next.set(c.id, c)
      _commentsById.value = next
      break
    }
    case 'turn_diff_snapshot':
      if (msg.diff) diffData.value = msg.diff
      break
  }
}

export {
  activeFile,
  addComment,
  closeReviewPanel,
  diffData,
  diffLoading,
  handleReviewWsEvent,
  loadComments,
  loadDiff,
  openReviewPanel,
  removeComment,
  resetReview,
  reviewComments,
  reviewError,
  reviewPanelOpen,
  updateComment,
}
