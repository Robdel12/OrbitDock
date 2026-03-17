import styles from './app-shell.module.css'
import { Sidebar } from './sidebar.jsx'

const AppShell = ({ routes, onCreateSession, children }) => (
  <div class={styles.shell}>
    <Sidebar routes={routes} onCreateSession={onCreateSession} />
    <div class={styles.main}>
      <div class={styles.content}>{children}</div>
    </div>
  </div>
)

export { AppShell }
