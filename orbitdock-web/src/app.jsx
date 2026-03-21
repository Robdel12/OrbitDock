import { useState, useEffect } from 'preact/hooks'
import { Router, Route, Switch, useLocation } from 'wouter-preact'
import { routes } from './routes.js'
import { AppShell } from './components/layout/app-shell.jsx'
import { CreateSessionDialog } from './components/session/create-session-dialog.jsx'
import { CommandPalette } from './components/command-palette/command-palette.jsx'
import { ErrorBoundary } from './components/ui/error-boundary.jsx'
import { ToastContainer } from './components/toast/toast-container.jsx'
import { OfflineIndicator } from './components/ui/offline-indicator.jsx'
import { KeyboardHelp } from './components/keyboard-help/keyboard-help.jsx'
import { http } from './stores/connection.js'
import { showCreateDialog } from './stores/sessions.js'
import { initTabIndicator } from './lib/tab-indicator.js'

const AppContent = () => {
  const [showCreate, setShowCreate] = useState(false)
  const [showKeyboardHelp, setShowKeyboardHelp] = useState(false)
  const [, navigate] = useLocation()

  // Initialise tab title + favicon updates.
  useEffect(() => {
    const unsubscribe = initTabIndicator()
    return unsubscribe
  }, [])

  // Bridge the showCreateDialog signal to local state so any component can trigger
  // the create session dialog without prop drilling.
  useEffect(() => {
    return showCreateDialog.subscribe((v) => {
      if (v) {
        setShowCreate(true)
        showCreateDialog.value = false
      }
    })
  }, [])

  // Global `?` shortcut to open keyboard help (skip when inside editable elements).
  useEffect(() => {
    const onKeyDown = (e) => {
      const tag = e.target.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return
      if (e.target.isContentEditable) return
      if (e.key === '?') {
        e.preventDefault()
        setShowKeyboardHelp((v) => !v)
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  const handleCreate = async (body) => {
    const data = await http.post('/api/sessions', body)
    if (data.session_id) {
      navigate(`/session/${data.session_id}`)
    }
  }

  return (
    <AppShell routes={routes} onCreateSession={() => setShowCreate(true)}>
      <Switch>
        {routes.map((r) => (
          <Route key={r.path} path={r.path} component={r.component} />
        ))}
      </Switch>
      <CreateSessionDialog
        open={showCreate}
        onClose={() => setShowCreate(false)}
        onCreate={handleCreate}
        http={http}
      />
      <CommandPalette onCreateSession={() => setShowCreate(true)} />
      {showKeyboardHelp && (
        <KeyboardHelp onClose={() => setShowKeyboardHelp(false)} />
      )}
    </AppShell>
  )
}

const App = () => (
  <Router>
    <ErrorBoundary>
      <OfflineIndicator />
      <AppContent />
      <ToastContainer />
    </ErrorBoundary>
  </Router>
)

export { App }
