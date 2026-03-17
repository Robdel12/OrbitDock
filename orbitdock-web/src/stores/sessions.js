import { signal, computed } from '@preact/signals'
import { groupByRepo } from '../lib/group-sessions.js'

const sessions = signal(new Map())
const selectedId = signal(null)

const selected = computed(() =>
  selectedId.value ? sessions.value.get(selectedId.value) : undefined
)

const grouped = computed(() =>
  groupByRepo([...sessions.value.values()])
)

const handleSessionsList = (list) => {
  const map = new Map()
  for (const s of list) map.set(s.id, s)
  sessions.value = map
}

const handleSessionCreated = (session) => {
  const next = new Map(sessions.value)
  next.set(session.id, session)
  sessions.value = next
}

const handleSessionListItemUpdated = (session) => {
  const next = new Map(sessions.value)
  next.set(session.id, session)
  sessions.value = next
}

const handleSessionDelta = (sessionId, changes) => {
  const current = sessions.value.get(sessionId)
  if (!current) return
  const next = new Map(sessions.value)
  const updated = { ...current }
  if (changes.status != null) updated.status = changes.status
  if (changes.work_status != null) updated.work_status = changes.work_status
  if (changes.custom_name !== undefined) updated.custom_name = changes.custom_name
  if (changes.summary !== undefined) updated.summary = changes.summary
  if (changes.first_prompt !== undefined) updated.first_prompt = changes.first_prompt
  if (changes.last_message !== undefined) updated.last_message = changes.last_message
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
  sessions,
  selectedId,
  selected,
  grouped,
  selectSession,
  handleSessionsList,
  handleSessionCreated,
  handleSessionListItemUpdated,
  handleSessionDelta,
  handleSessionEnded,
  handleSessionRemoved,
}
