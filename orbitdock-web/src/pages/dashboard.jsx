import { useState, useMemo } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { SessionList } from '../components/session/session-list.jsx'
import { FilterToolbar } from '../components/dashboard/filter-toolbar.jsx'
import { UsageSummary } from '../components/dashboard/usage-summary.jsx'
import { DashboardSkeleton } from '../components/dashboard/dashboard-skeleton.jsx'
import { selectSession, sessions } from '../stores/sessions.js'
import { connectionState } from '../stores/connection.js'
import { groupByRepo, extractRepoName } from '../lib/group-sessions.js'
import { useKeyboard } from '../hooks/use-keyboard.js'
import styles from './dashboard.module.css'

const DEFAULT_FILTERS = { provider: 'all', status: 'all', repo: 'all' }
const DEFAULT_SORT = 'activity'

// Sort a flat list of sessions according to the sort key.
// groupByRepo already handles the "activity" sort by latest group time — we
// pass the sorted flat list into groupByRepo so that inner sorting is consistent.
const sortSessions = (list, sort) => {
  if (sort === 'activity') {
    // groupByRepo will sort internally; return the list as-is so its logic applies
    return list
  }
  const copy = [...list]
  if (sort === 'name') {
    copy.sort((a, b) => {
      const aName = (a.custom_name || a.summary || a.first_prompt || a.id).toLowerCase()
      const bName = (b.custom_name || b.summary || b.first_prompt || b.id).toLowerCase()
      return aName.localeCompare(bName)
    })
  } else if (sort === 'status') {
    copy.sort((a, b) => {
      const order = { active: 0, ended: 1 }
      const aO = order[a.status] ?? 1
      const bO = order[b.status] ?? 1
      return aO - bO
    })
  }
  return copy
}

const DashboardPage = () => {
  const [, navigate] = useLocation()
  const [selectedIndex, setSelectedIndex] = useState(-1)
  const [filters, setFilters] = useState(DEFAULT_FILTERS)
  const [sort, setSort] = useState(DEFAULT_SORT)

  const allSessions = [...sessions.value.values()]

  // Derive repo list from all sessions (unfiltered) for the repo dropdown.
  const repos = useMemo(() => {
    const seen = new Map()
    for (const s of allSessions) {
      const path = s.repository_root || s.project_path || 'Unknown'
      if (!seen.has(path)) seen.set(path, { path, name: extractRepoName(path) })
    }
    return [...seen.values()].sort((a, b) => a.name.localeCompare(b.name))
    // sessions.value — signal reference — changes whenever the map is replaced,
    // which covers additions, removals, and field mutations.
  }, [sessions.value])

  // Apply filters then sort then group.
  const groups = useMemo(() => {
    let filtered = allSessions

    if (filters.provider !== 'all') {
      filtered = filtered.filter((s) => s.provider === filters.provider)
    }
    if (filters.status !== 'all') {
      filtered = filtered.filter((s) => s.status === filters.status)
    }
    if (filters.repo !== 'all') {
      filtered = filtered.filter(
        (s) => (s.repository_root || s.project_path || 'Unknown') === filters.repo
      )
    }

    const sorted = sortSessions(filtered, sort)
    return groupByRepo(sorted)
  }, [sessions.value, filters, sort])

  // Flat ordered list for keyboard nav — mirrors the visual order after grouping.
  const sessionList = useMemo(
    () => groups.flatMap((g) => g.sessions),
    [groups]
  )

  const handleSelect = (id) => {
    selectSession(id)
    navigate(`/session/${id}`)
  }

  useKeyboard({
    ArrowDown: () => setSelectedIndex((i) => Math.min(i + 1, sessionList.length - 1)),
    ArrowUp: () => setSelectedIndex((i) => Math.max(i - 1, 0)),
    j: () => setSelectedIndex((i) => Math.min(i + 1, sessionList.length - 1)),
    k: () => setSelectedIndex((i) => Math.max(i - 1, 0)),
    Enter: () => {
      if (selectedIndex >= 0 && selectedIndex < sessionList.length) {
        handleSelect(sessionList[selectedIndex].id)
      }
    },
  })

  // Show the skeleton while the WS session list hasn't arrived yet.
  // Once connected the sessions map is populated; until then it stays empty.
  const connState = connectionState.value
  const isLoading = sessions.value.size === 0 && connState !== 'connected'

  if (isLoading) return <DashboardSkeleton />

  return (
    <div class={styles.page}>
      <UsageSummary />
      <FilterToolbar
        filters={filters}
        onFiltersChange={setFilters}
        sort={sort}
        onSortChange={setSort}
        repos={repos}
      />
      <SessionList groups={groups} onSelect={handleSelect} />
    </div>
  )
}

export { DashboardPage }
