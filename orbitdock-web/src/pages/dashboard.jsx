import { useMemo, useState } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { DashboardSkeleton } from '../components/dashboard/dashboard-skeleton.jsx'
import { FilterToolbar } from '../components/dashboard/filter-toolbar.jsx'
import { UsageSummary } from '../components/dashboard/usage-summary.jsx'
import { classifyZone, SessionList } from '../components/session/session-list.jsx'
import { useKeyboard } from '../hooks/use-keyboard.js'
import { extractRepoName, groupByRepo } from '../lib/group-sessions.js'
import { connectionState } from '../stores/connection.js'
import { selectSession, sessions, showCreateDialog } from '../stores/sessions.js'
import styles from './dashboard.module.css'

const DEFAULT_FILTERS = { zone: 'all', repo: 'all' }
const DEFAULT_SORT = 'activity'

const getGreeting = () => {
  const hour = new Date().getHours()
  if (hour < 12) return 'Good morning'
  if (hour < 17) return 'Good afternoon'
  return 'Good evening'
}

// Sort a flat list of sessions according to the sort key.
const sortSessions = (list, sort) => {
  if (sort === 'activity') return list
  const copy = [...list]
  if (sort === 'name') {
    copy.sort((a, b) => {
      const aName = (a.display_title || a.custom_name || a.summary || a.first_prompt || a.id).toLowerCase()
      const bName = (b.display_title || b.custom_name || b.summary || b.first_prompt || b.id).toLowerCase()
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

const PlusIcon = () => (
  <svg
    width="20"
    height="20"
    viewBox="0 0 16 16"
    fill="none"
    stroke="currentColor"
    stroke-width="2.5"
    stroke-linecap="round"
  >
    <path d="M8 3v10M3 8h10" />
  </svg>
)

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
      baseList = baseList.filter((s) => (s.repository_root || s.project_path || 'Unknown') === filters.repo)
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
      filtered = filtered.filter((s) => (s.repository_root || s.project_path || 'Unknown') === filters.repo)
    }

    const sorted = sortSessions(filtered, sort)
    return groupByRepo(sorted)
  }, [sessions.value, filters, sort])

  // Flat ordered list for keyboard nav.
  const sessionList = useMemo(() => groups.flatMap((g) => g.sessions), [groups])

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

  // Build the stat summary line
  const summaryParts = []
  if (zoneCounts.total > 0) {
    const active = zoneCounts.working + zoneCounts.attention + zoneCounts.ready
    summaryParts.push(
      <span key="active">
        <span class={styles.greetingCount}>{active}</span> session{active !== 1 ? 's' : ''} active
      </span>,
    )
  }
  if (zoneCounts.attention > 0) {
    summaryParts.push(
      <span key="attn">
        <span class={`${styles.greetingCount} ${styles.greetingCountAttention}`}>{zoneCounts.attention}</span> need
        {zoneCounts.attention !== 1 ? '' : 's'} attention
      </span>,
    )
  }
  if (zoneCounts.working > 0) {
    summaryParts.push(
      <span key="work">
        <span class={`${styles.greetingCount} ${styles.greetingCountWorking}`}>{zoneCounts.working}</span> running
      </span>,
    )
  }

  return (
    <div class={styles.page}>
      <div class={styles.pageHeader}>
        <div class={styles.greeting}>
          <span class={styles.greetingText}>{getGreeting()}</span>
          {summaryParts.length > 0 && (
            <span class={styles.greetingSummary}>
              {summaryParts.reduce((acc, part, i) => {
                if (i === 0) return [part]
                return [
                  ...acc,
                  <span key={`sep-${i}`} class={styles.greetingSep}>
                    {' '}
                    ·{' '}
                  </span>,
                  part,
                ]
              }, [])}
            </span>
          )}
        </div>
        <UsageSummary />
      </div>

      <div class={styles.stickyToolbar}>
        <FilterToolbar
          filters={filters}
          onFiltersChange={setFilters}
          sort={sort}
          onSortChange={setSort}
          repos={repos}
          zoneCounts={zoneCounts}
        />
      </div>

      <div class={styles.scrollArea}>
        <SessionList groups={groups} onSelect={handleSelect} />
      </div>

      {/* Mobile floating action button */}
      <button
        class={styles.fab}
        onClick={() => {
          showCreateDialog.value = true
        }}
        aria-label="New Session"
      >
        <PlusIcon />
      </button>
    </div>
  )
}

export { DashboardPage }
