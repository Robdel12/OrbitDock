import { useCallback, useEffect, useState } from 'preact/hooks'
import { isAuthenticated, setToken, token } from '../../stores/auth.js'
import { connect, probeAuth } from '../../stores/connection.js'
import { Button } from '../ui/button.jsx'
import styles from './auth-gate.module.css'

const WS_URL = `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`

const AuthGate = ({ children }) => {
  const [phase, setPhase] = useState('probing') // probing | needs_token | ready | error
  const [input, setInput] = useState('')
  const [validating, setValidating] = useState(false)
  const [errorMsg, setErrorMsg] = useState('')

  const probe = useCallback(async () => {
    setPhase('probing')
    const result = await probeAuth()
    if (result === 'ok') {
      connect(WS_URL)
      setPhase('ready')
    } else if (result === 'auth_required') {
      if (isAuthenticated.value) {
        // Had a stored token but it's invalid
        setErrorMsg('Stored token is invalid or expired.')
      }
      setPhase('needs_token')
    } else {
      setPhase('error')
    }
  }, [])

  useEffect(() => {
    probe()
  }, [probe])

  // When auth store token is cleared (e.g. 401 during session), go back to login
  useEffect(() => {
    const unsub = token.subscribe((val) => {
      if (!val && phase === 'ready') {
        setPhase('needs_token')
        setErrorMsg('Session expired. Please re-enter your token.')
      }
    })
    return unsub
  }, [phase])

  const handleSubmit = async (e) => {
    e.preventDefault()
    const trimmed = input.trim()
    if (!trimmed) return

    setValidating(true)
    setErrorMsg('')

    try {
      const res = await fetch('/api/sessions', {
        headers: { Authorization: `Bearer ${trimmed}` },
      })
      if (res.status === 401) {
        setErrorMsg('Invalid token. Check that you pasted the full token.')
        setValidating(false)
        return
      }
      if (!res.ok) {
        setErrorMsg(`Server error (${res.status})`)
        setValidating(false)
        return
      }
      // Token is valid — persist and connect
      setToken(trimmed)
      connect(WS_URL)
      setPhase('ready')
    } catch {
      setErrorMsg('Could not reach the server.')
    } finally {
      setValidating(false)
    }
  }

  if (phase === 'probing') {
    return (
      <div class={styles.container}>
        <div class={styles.card}>
          <div class={styles.spinner} />
          <p class={styles.statusText}>Connecting to server...</p>
        </div>
      </div>
    )
  }

  if (phase === 'error') {
    return (
      <div class={styles.container}>
        <div class={styles.card}>
          <h1 class={styles.title}>Server Unreachable</h1>
          <p class={styles.hint}>Could not connect to the OrbitDock server. Make sure it is running.</p>
          <Button variant="secondary" onClick={probe}>
            Retry
          </Button>
        </div>
      </div>
    )
  }

  if (phase === 'needs_token') {
    return (
      <div class={styles.container}>
        <div class={styles.card}>
          <h1 class={styles.title}>OrbitDock</h1>
          <p class={styles.hint}>
            This server requires an auth token. Paste your <code>odtk_</code> token below.
          </p>
          <form class={styles.form} onSubmit={handleSubmit}>
            <input
              class={styles.input}
              type="password"
              placeholder="odtk_..."
              value={input}
              onInput={(e) => setInput(e.target.value)}
              autoFocus
              spellCheck={false}
              autoComplete="off"
            />
            {errorMsg && <p class={styles.error}>{errorMsg}</p>}
            <Button variant="primary" size="md" loading={validating} disabled={!input.trim()}>
              Connect
            </Button>
          </form>
        </div>
      </div>
    )
  }

  return children
}

export { AuthGate }
