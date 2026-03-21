import { useLocation, Link } from 'wouter-preact'
import { grouped } from '../../stores/sessions.js'
import { connectionState } from '../../stores/connection.js'
import { StatusDot } from '../ui/status-dot.jsx'
import { formatRelativeTime } from '../../lib/format.js'
import styles from './sidebar.module.css'

const NAV_ICONS = {
  LayoutDashboard: (
    <svg class={styles.navIcon} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
      <rect x="1.5" y="1.5" width="5" height="6" rx="1" />
      <rect x="9.5" y="1.5" width="5" height="3" rx="1" />
      <rect x="9.5" y="7.5" width="5" height="7" rx="1" />
      <rect x="1.5" y="10.5" width="5" height="4" rx="1" />
    </svg>
  ),
  Rocket: (
    <svg class={styles.navIcon} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
      <path d="M8 14s-2-3-2-6c0-3.5 2-6 2-6s2 2.5 2 6-2 6-2 6z" />
      <path d="M4.5 10.5C3 11 2 12.5 2 12.5l2.5-0.5" />
      <path d="M11.5 10.5C13 11 14 12.5 14 12.5l-2.5-0.5" />
      <circle cx="8" cy="6" r="1" fill="currentColor" stroke="none" />
    </svg>
  ),
  GitBranch: (
    <svg class={styles.navIcon} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="5" cy="4" r="1.5" />
      <circle cx="5" cy="12" r="1.5" />
      <circle cx="11" cy="6" r="1.5" />
      <path d="M5 5.5v5M11 7.5c0 2-2 2.5-6 3" />
    </svg>
  ),
  Settings: (
    <svg class={styles.navIcon} viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="8" cy="8" r="2.5" />
      <path d="M8 1.5v2M8 12.5v2M1.5 8h2M12.5 8h2M3.1 3.1l1.4 1.4M11.5 11.5l1.4 1.4M3.1 12.9l1.4-1.4M11.5 4.5l1.4-1.4" />
    </svg>
  ),
}

const Sidebar = ({ routes, onCreateSession, open, onClose }) => {
  const [location] = useLocation()
  const navRoutes = routes.filter((r) => r.showInNav)
  const groups = grouped.value
  const connState = connectionState.value

  const handleNavClick = () => {
    // Close sidebar on mobile after navigating
    onClose?.()
  }

  return (
    <>
      {/* Backdrop — only rendered on mobile when sidebar is open */}
      {open && (
        <div
          class={styles.backdrop}
          onClick={onClose}
          aria-hidden="true"
        />
      )}

      <aside
        class={`${styles.sidebar} ${open ? styles.sidebarOpen : ''}`}
      >
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
              onClick={handleNavClick}
            >
              {NAV_ICONS[route.icon] || null}
              {route.label}
            </Link>
          ))}
        </nav>

        <div class={styles.sessions}>
          {groups.map((group) => (
            <div key={group.path} class={styles.group}>
              <div class={styles.groupLabel}>{group.name}</div>
              {group.sessions.map((session) => {
                const name = session.display_title || session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`
                const isSelected = location === `/session/${session.id}`
                const provider = session.provider
                return (
                  <Link
                    key={session.id}
                    href={`/session/${session.id}`}
                    class={`${styles.sessionItem} ${isSelected ? styles.sessionActive : ''}`}
                    onClick={handleNavClick}
                  >
                    <StatusDot status={session.work_status} />
                    <div class={styles.sessionText}>
                      <span class={styles.sessionName}>{name}</span>
                      <span class={styles.sessionMeta}>
                        {provider && (
                          <span class={styles.sessionProvider}>{provider}</span>
                        )}
                        {session.last_activity_at && (
                          <span class={styles.sessionTime}>{formatRelativeTime(session.last_activity_at)}</span>
                        )}
                        {session.is_worktree && session.worktree_id && (
                          <span class={styles.sessionWorktree}><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="6" y1="3" x2="6" y2="15"/><circle cx="18" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M18 9a9 9 0 0 1-9 9"/></svg></span>
                        )}
                      </span>
                    </div>
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
    </>
  )
}

export { Sidebar }
