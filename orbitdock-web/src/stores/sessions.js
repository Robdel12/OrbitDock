import { computed, signal } from '@preact/signals'
import { groupByRepo } from '../lib/group-sessions.js'

const sessions = signal(new Map())
const selectedId = signal(null)
const showCreateDialog = signal(false)

const selected = computed(() => (selectedId.value ? sessions.value.get(selectedId.value) : undefined))

const grouped = computed(() => groupByRepo([...sessions.value.values()]))

// Normalize backend field names so frontend code uses consistent names.
// SessionListItem sends git_branch/display_title/context_line.
// SessionState sends git_branch/custom_name/summary/first_prompt.
// We alias git_branch → branch for convenience and keep all original fields.
const normalize = (s) => {
  if (!s) return s
  const out = { ...s }
  if (s.git_branch !== undefined && s.branch === undefined) out.branch = s.git_branch
  return out
}

const handleSessionsList = (list) => {
  const map = new Map()
  for (const s of list) map.set(s.id, normalize(s))
  sessions.value = map
}

const handleSessionCreated = (session) => {
  const next = new Map(sessions.value)
  next.set(session.id, normalize(session))
  sessions.value = next
}

const handleSessionListItemUpdated = (session) => {
  const next = new Map(sessions.value)
  next.set(session.id, normalize(session))
  sessions.value = next
}

const handleSessionDelta = (sessionId, changes) => {
  const current = sessions.value.get(sessionId)
  if (!current) return
  const next = new Map(sessions.value)
  const updated = { ...current }
  if (changes.status != null) updated.status = changes.status
  if (changes.work_status != null) updated.work_status = changes.work_status
  if (changes.steerable != null) updated.steerable = changes.steerable
  if (changes.custom_name !== undefined) updated.custom_name = changes.custom_name
  if (changes.summary !== undefined) updated.summary = changes.summary
  if (changes.first_prompt !== undefined) updated.first_prompt = changes.first_prompt
  if (changes.last_message !== undefined) updated.last_message = changes.last_message
  if (changes.git_branch !== undefined) {
    updated.git_branch = changes.git_branch
    updated.branch = changes.git_branch
  }
  if (changes.permission_mode !== undefined) updated.permission_mode = changes.permission_mode
  // Recompute display_title when the underlying name fields change
  if (changes.custom_name !== undefined || changes.summary !== undefined || changes.first_prompt !== undefined) {
    updated.display_title = updated.custom_name || updated.summary || updated.first_prompt || updated.display_title
  }
  next.set(sessionId, updated)
  sessions.value = next
}

const handleSessionEnded = (sessionId) => {
  const current = sessions.value.get(sessionId)
  if (!current) return
  const next = new Map(sessions.value)
  next.set(sessionId, { ...current, status: 'ended', work_status: 'ended' })
  sessions.value = next
}

const applyResumeSummary = (sessionId, summary) => {
  const current = sessions.value.get(sessionId)
  if (!current) return
  const merged = { ...current, ...summary }
  // Re-derive branch from git_branch so stale alias doesn't persist
  if (summary.git_branch !== undefined) merged.branch = summary.git_branch
  const next = new Map(sessions.value)
  next.set(sessionId, normalize(merged))
  sessions.value = next
}

const handleSessionRemoved = (sessionId) => {
  const next = new Map(sessions.value)
  next.delete(sessionId)
  sessions.value = next
  if (selectedId.value === sessionId) selectedId.value = null
}

const selectSession = (id) => {
  selectedId.value = id
}

export {
  applyResumeSummary,
  grouped,
  handleSessionCreated,
  handleSessionDelta,
  handleSessionEnded,
  handleSessionListItemUpdated,
  handleSessionRemoved,
  handleSessionsList,
  selected,
  selectedId,
  selectSession,
  sessions,
  showCreateDialog,
}
