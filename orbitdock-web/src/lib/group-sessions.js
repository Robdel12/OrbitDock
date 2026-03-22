const groupByRepo = (sessions) => {
  const groups = new Map()
  for (const session of sessions) {
    const key = session.repository_root || session.project_path || 'Unknown'
    if (!groups.has(key)) {
      groups.set(key, { path: key, name: extractRepoName(key), sessions: [] })
    }
    groups.get(key).sessions.push(session)
  }
  const result = [...groups.values()]
  result.sort((a, b) => {
    const aLatest = latestActivity(a.sessions)
    const bLatest = latestActivity(b.sessions)
    return bLatest - aLatest
  })
  for (const group of result) {
    group.sessions.sort((a, b) => {
      const statusOrder = { active: 0, ended: 1 }
      const aOrder = statusOrder[a.status] ?? 1
      const bOrder = statusOrder[b.status] ?? 1
      if (aOrder !== bOrder) return aOrder - bOrder
      const aTime = a.last_activity_at ? new Date(a.last_activity_at).getTime() : 0
      const bTime = b.last_activity_at ? new Date(b.last_activity_at).getTime() : 0
      return bTime - aTime
    })
  }
  return result
}

const extractRepoName = (path) => {
  if (!path) return 'Unknown'
  const parts = path.replace(/\/$/, '').split('/')
  return parts[parts.length - 1] || path
}

const latestActivity = (sessions) => {
  let latest = 0
  for (const s of sessions) {
    const t = s.last_activity_at ? new Date(s.last_activity_at).getTime() : 0
    if (t > latest) latest = t
  }
  return latest
}

export { extractRepoName, groupByRepo }
