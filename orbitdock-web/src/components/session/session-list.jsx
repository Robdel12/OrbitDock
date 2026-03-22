import { useMemo } from 'preact/hooks'
import { showCreateDialog } from '../../stores/sessions.js'
import { SessionCard } from './session-card.jsx'
import styles from './session-list.module.css'

// ---------------------------------------------------------------------------
// Zone classification — triage sessions into Attention / Working / Ready
// ---------------------------------------------------------------------------

const classifyZone = (session) => {
  const ws = session.work_status
  if (ws === 'permission' || ws === 'question') return 'attention'
  if (ws === 'working') return 'working'
  return 'ready'
}

const ZONE_CONFIG = {
  attention: {
    label: 'Needs Attention',
    colorVar: '--color-status-permission',
  },
  working: {
    label: 'Working',
    colorVar: '--color-status-working',
  },
  ready: {
    label: 'Ready',
    colorVar: '--color-status-reply',
  },
}

// Zone icons as inline SVGs — 14×14
const ZoneIcon = ({ zone }) => {
  if (zone === 'attention') {
    return (
      <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
        <path d="M8 1a7 7 0 100 14A7 7 0 008 1zm-.5 4a.5.5 0 011 0v3.5a.5.5 0 01-1 0V5zM8 11.5a.75.75 0 110-1.5.75.75 0 010 1.5z" />
      </svg>
    )
  }
  if (zone === 'working') {
    return (
      <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
        <path d="M9.3 2.1a.6.6 0 00-1 .4v4H5.5a.6.6 0 00-.5.9l3.2 6.5a.6.6 0 001-.4v-4h2.8a.6.6 0 00.5-.9L9.3 2.1z" />
      </svg>
    )
  }
  // ready
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
      <path d="M2 3.5A1.5 1.5 0 013.5 2h9A1.5 1.5 0 0114 3.5v7a1.5 1.5 0 01-1.5 1.5H6l-3 2.5V12H3.5A1.5 1.5 0 012 10.5v-7z" />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Zone header — icon + label + count pill + divider line
// ---------------------------------------------------------------------------

const ZoneHeader = ({ zone, count }) => {
  const config = ZONE_CONFIG[zone]
  return (
    <div class={styles.zoneHeader} style={{ '--zone-color': `var(${config.colorVar})` }}>
      <span class={styles.zoneIcon}>
        <ZoneIcon zone={zone} />
      </span>
      <span class={styles.zoneLabel}>{config.label}</span>
      <span class={styles.zoneCount}>{count}</span>
      <span class={styles.zoneDivider} />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Orbital ring SVG for empty state
// ---------------------------------------------------------------------------

const OrbitalRing = () => (
  <svg width="64" height="64" viewBox="0 0 64 64" fill="none">
    <circle cx="32" cy="32" r="24" stroke="currentColor" stroke-width="1.5" stroke-dasharray="4 3" opacity="0.4" />
    <circle cx="32" cy="32" r="4" fill="currentColor" opacity="0.6" />
  </svg>
)

// ---------------------------------------------------------------------------
// Session list — zone-based layout
// ---------------------------------------------------------------------------

const SessionList = ({ groups, onSelect }) => {
  // groups is still passed for backwards compat, but we re-triage into zones
  const allSessions = useMemo(() => groups.flatMap((g) => g.sessions), [groups])

  const zones = useMemo(() => {
    const attention = []
    const working = []
    const ready = []

    for (const session of allSessions) {
      const zone = classifyZone(session)
      if (zone === 'attention') attention.push(session)
      else if (zone === 'working') working.push(session)
      else ready.push(session)
    }

    // Sort within each zone by last_activity_at descending
    const byActivity = (a, b) => {
      const aTime = a.last_activity_at ? new Date(a.last_activity_at).getTime() : 0
      const bTime = b.last_activity_at ? new Date(b.last_activity_at).getTime() : 0
      return bTime - aTime
    }

    attention.sort(byActivity)
    working.sort(byActivity)
    ready.sort(byActivity)

    return { attention, working, ready }
  }, [allSessions])

  if (allSessions.length === 0) {
    return (
      <div class={styles.empty}>
        <div class={styles.emptyIcon}>
          <OrbitalRing />
        </div>
        <p class={styles.emptyTitle}>Mission Control is clear</p>
        <p class={styles.emptyDesc}>Start a new session to begin working with your AI agents.</p>
        <button
          class={styles.emptyCta}
          onClick={() => {
            showCreateDialog.value = true
          }}
        >
          <svg
            width="16"
            height="16"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            stroke-linecap="round"
          >
            <path d="M8 3v10M3 8h10" />
          </svg>
          New Session
        </button>
      </div>
    )
  }

  return (
    <div class={styles.list}>
      {zones.attention.length > 0 && (
        <div class={styles.zone}>
          <ZoneHeader zone="attention" count={zones.attention.length} />
          <div class={`${styles.zoneCards} ${styles.zoneCardsAttention}`}>
            {zones.attention.map((session) => (
              <SessionCard
                key={session.id}
                session={session}
                variant="attention"
                onClick={() => onSelect(session.id)}
              />
            ))}
          </div>
        </div>
      )}

      {zones.working.length > 0 && (
        <div class={styles.zone}>
          <ZoneHeader zone="working" count={zones.working.length} />
          <div class={`${styles.zoneCards} ${zones.working.length > 1 ? styles.zoneCardsGrid : ''}`}>
            {zones.working.map((session) => (
              <SessionCard key={session.id} session={session} variant="working" onClick={() => onSelect(session.id)} />
            ))}
          </div>
        </div>
      )}

      {zones.ready.length > 0 && (
        <div class={styles.zone}>
          <ZoneHeader zone="ready" count={zones.ready.length} />
          <div class={styles.zoneCards}>
            {zones.ready.map((session) => (
              <SessionCard key={session.id} session={session} variant="ready" onClick={() => onSelect(session.id)} />
            ))}
          </div>
        </div>
      )}
    </div>
  )
}

export { classifyZone, SessionList }
