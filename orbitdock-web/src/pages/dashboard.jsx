import { useState, useMemo } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { SessionList, classifyZone } from '../components/session/session-list.jsx'
import { FilterToolbar } from '../components/dashboard/filter-toolbar.jsx'
import { UsageSummary } from '../components/dashboard/usage-summary.jsx'
import { DashboardSkeleton } from '../components/dashboard/dashboard-skeleton.jsx'
import { selectSession, sessions } from '../stores/sessions.js'
import { connectionState } from '../stores/connection.js'
import { groupByRepo, extractRepoName } from '../lib/group-sessions.js'
import { useKeyboard } from '../hooks/use-keyboard.js'
import styles from './dashboard.module.css'

const DEFAULT_FILTERS = { zone: 'all', repo: 'all' }
const DEFAULT_SORT = 'activity'

// Sort a flat list of sessions according to the sort key.
const sortSessions = (list, sort) => {
  if (sort === 'activity') return list
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
  }, [sessions.value])

  // Compute zone counts (before zone filter, after repo filter)
  const zoneCounts = useMemo(() => {
    let baseList = allSessions
    if (filters.repo !== 'all') {
      baseList = baseList.filter(
        (s) => (s.repository_root || s.project_path || 'Unknown') === filters.repo
      )
    }
    const counts = { attention: 0, working: 0, ready: 0, total: baseList.length }
    for (const s of baseList) {
      const zone = classifyZone(s)
      counts[zone]++
    }
    return counts
  }, [sessions.value, filters.repo])

  // Apply filters then sort then group.
  const groups = useMemo(() => {
    let filtered = allSessions

    // Zone filter
    if (filters.zone && filters.zone !== 'all') {
      filtered = filtered.filter((s) => classifyZone(s) === filters.zone)
    }

    if (filters.repo !== 'all') {
      filtered = filtered.filter(
        (s) => (s.repository_root || s.project_path || 'Unknown') === filters.repo
      )
    }

    const sorted = sortSessions(filtered, sort)
    return groupByRepo(sorted)
  }, [sessions.value, filters, sort])

  // Flat ordered list for keyboard nav.
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
        zoneCounts={zoneCounts}
      />
      <SessionList groups={groups} onSelect={handleSelect} />
    </div>
  )
}

export { DashboardPage }
