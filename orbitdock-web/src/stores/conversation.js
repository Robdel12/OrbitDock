import { signal } from '@preact/signals'

const createConversationStore = () => {
  const rows = signal([])
  const totalCount = signal(0)
  const hasMoreBefore = signal(false)
  const isLoadingHistory = signal(false)
  const oldestSequence = signal(null)

  const applyBootstrap = (page) => {
    rows.value = page.rows || []
    totalCount.value = page.total_row_count || 0
    hasMoreBefore.value = page.has_more_before || false
    oldestSequence.value = page.oldest_sequence ?? null
  }

  const applyRowsChanged = ({ upserted, removed_row_ids, total_row_count }) => {
    let current = [...rows.value]

    if (removed_row_ids && removed_row_ids.length > 0) {
      const removeSet = new Set(removed_row_ids)
      current = current.filter((entry) => !removeSet.has(entry.row?.id ?? entryId(entry)))
    }

    if (upserted && upserted.length > 0) {
      for (const entry of upserted) {
        const id = entryId(entry)
        const idx = current.findIndex((e) => entryId(e) === id)
        if (idx >= 0) {
          current[idx] = entry
        } else {
          current.push(entry)
        }
      }
    }

    current.sort((a, b) => a.sequence - b.sequence)
    rows.value = current
    if (total_row_count != null) totalCount.value = total_row_count
  }

  const loadOlder = async (http, sessionId) => {
    if (isLoadingHistory.value || !hasMoreBefore.value) return
    isLoadingHistory.value = true
    try {
      const oldest = oldestSequence.value
      const params = { limit: '50' }
      if (oldest != null) params.before_sequence = String(oldest)
      const data = await http.get(`/api/sessions/${sessionId}/messages`, params)
      const page = data.rows ? data : { rows: data }
      const current = [...rows.value]
      const existingIds = new Set(current.map(entryId))
      const newRows = (page.rows || []).filter((e) => !existingIds.has(entryId(e)))
      const merged = [...newRows, ...current].sort((a, b) => a.sequence - b.sequence)
      rows.value = merged
      totalCount.value = data.total_row_count ?? totalCount.value
      hasMoreBefore.value = data.has_more_before ?? false
      oldestSequence.value = data.oldest_sequence ?? oldestSequence.value
    } finally {
      isLoadingHistory.value = false
    }
  }

  const clear = () => {
    rows.value = []
    totalCount.value = 0
    hasMoreBefore.value = false
    oldestSequence.value = null
  }

  return {
    rows,
    totalCount,
    hasMoreBefore,
    isLoadingHistory,
    oldestSequence,
    applyBootstrap,
    applyRowsChanged,
    loadOlder,
    clear,
  }
}

const entryId = (entry) => {
  if (!entry.row) return entry.id || ''
  return entry.row.id || ''
}

export { createConversationStore, entryId }
