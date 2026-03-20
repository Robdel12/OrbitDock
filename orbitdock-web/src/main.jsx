import { render } from 'preact'
import { App } from './app.jsx'
import { AuthGate } from './components/auth/auth-gate.jsx'
import './styles/global.css'

render(
  <AuthGate>
    <App />
  </AuthGate>,
  document.getElementById('app'),
)
