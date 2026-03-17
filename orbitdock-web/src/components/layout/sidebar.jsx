import { useLocation, Link } from 'wouter-preact'
import { grouped } from '../../stores/sessions.js'
import { connectionState } from '../../stores/connection.js'
import { StatusDot } from '../ui/status-dot.jsx'
import { formatRelativeTime } from '../../lib/format.js'
import styles from './sidebar.module.css'

const Sidebar = ({ routes, onCreateSession }) => {
  const [location] = useLocation()
  const navRoutes = routes.filter((r) => r.showInNav)
  const groups = grouped.value
  const connState = connectionState.value

  return (
    <aside class={styles.sidebar}>
      <div class={styles.header}>
        <span class={styles.logo}>OrbitDock</span>
        <button class={styles.createBtn} onClick={onCreateSession} title="New Session">
          +
        </button>
      </div>

      <nav class={styles.nav}>
        {navRoutes.map((route) => (
          <Link
            key={route.path}
            href={route.path}
            class={`${styles.navItem} ${location === route.path ? styles.active : ''}`}
          >
            {route.label}
          </Link>
        ))}
      </nav>

      <div class={styles.sessions}>
        {groups.map((group) => (
          <div key={group.path} class={styles.group}>
            <div class={styles.groupLabel}>{group.name}</div>
            {group.sessions.map((session) => {
              const name = session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`
              const isSelected = location === `/session/${session.id}`
              return (
                <Link
                  key={session.id}
                  href={`/session/${session.id}`}
                  class={`${styles.sessionItem} ${isSelected ? styles.sessionActive : ''}`}
                >
                  <StatusDot status={session.work_status} />
                  <span class={styles.sessionName}>{name}</span>
                  {session.last_activity_at && (
                    <span class={styles.sessionTime}>{formatRelativeTime(session.last_activity_at)}</span>
                  )}
                </Link>
              )
            })}
          </div>
        ))}
      </div>

      <div class={styles.footer}>
        <span
          class={styles.statusDot}
          style={{
            background: connState === 'connected' ? 'var(--color-feedback-positive)'
              : connState === 'failed' ? 'var(--color-feedback-negative)'
              : 'var(--color-feedback-caution)',
          }}
        />
        <span class={styles.statusLabel}>
          {connState === 'connected' ? 'Connected' : connState === 'failed' ? 'Disconnected' : 'Connecting...'}
        </span>
      </div>
    </aside>
  )
}

export { Sidebar }
