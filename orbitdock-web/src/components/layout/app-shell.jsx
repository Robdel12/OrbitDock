import { useState } from 'preact/hooks'
import styles from './app-shell.module.css'
import { Sidebar } from './sidebar.jsx'

const AppShell = ({ routes, onCreateSession, children }) => {
  const [sidebarOpen, setSidebarOpen] = useState(false)

  return (
    <div class={styles.shell}>
      <Sidebar
        routes={routes}
        onCreateSession={onCreateSession}
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
      />
      <div class={styles.main}>
        {/* Hamburger button — only visible on mobile */}
        <button
          class={styles.hamburger}
          onClick={() => setSidebarOpen((v) => !v)}
          aria-label="Toggle navigation"
          aria-expanded={sidebarOpen}
        >
          <span class={styles.hamburgerLine} />
          <span class={styles.hamburgerLine} />
          <span class={styles.hamburgerLine} />
        </button>
        <div class={styles.content}>{children}</div>
      </div>
    </div>
  )
}

export { AppShell }
