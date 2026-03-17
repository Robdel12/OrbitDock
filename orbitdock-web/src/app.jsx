import { useState } from 'preact/hooks'
import { Router, Route, Switch, useLocation } from 'wouter-preact'
import { routes } from './routes.js'
import { AppShell } from './components/layout/app-shell.jsx'
import { CreateSessionDialog } from './components/session/create-session-dialog.jsx'
import { ErrorBoundary } from './components/ui/error-boundary.jsx'
import { http } from './stores/connection.js'

const AppContent = () => {
  const [showCreate, setShowCreate] = useState(false)
  const [, navigate] = useLocation()

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
    </AppShell>
  )
}

const App = () => (
  <Router>
    <ErrorBoundary>
      <AppContent />
    </ErrorBoundary>
  </Router>
)

export { App }
