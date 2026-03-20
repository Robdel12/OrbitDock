import { useState, useEffect, useRef } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import { Badge } from '../ui/badge.jsx'
import { Button } from '../ui/button.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './mcp-panel.module.css'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const serverStatusColor = (status) => {
  if (status === 'connected') return 'feedback-positive'
  if (status === 'error') return 'feedback-negative'
  if (status === 'connecting') return 'status-working'
  return 'status-ended'
}

const serverStatusLabel = (status) => {
  if (status === 'connected') return 'connected'
  if (status === 'error') return 'error'
  if (status === 'connecting') return 'connecting'
  return 'disconnected'
}

// ---------------------------------------------------------------------------
// Auth flow component — shows an OAuth/API-key input inline
// ---------------------------------------------------------------------------

const AuthFlow = ({ server, sessionId, onDone }) => {
  const [value, setValue] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [authError, setAuthError] = useState(null)
  const inputRef = useRef(null)

  useEffect(() => {
    inputRef.current?.focus()
  }, [])

  const handleSubmit = async (e) => {
    e.preventDefault()
    const trimmed = value.trim()
    if (!trimmed) return
    setSubmitting(true)
    setAuthError(null)
    try {
      await http.post(`/api/sessions/${sessionId}/mcp/authenticate`, {
        server_name: server.name,
        credential: trimmed,
      })
      onDone()
    } catch (err) {
      setAuthError(err.message)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <form class={styles.authForm} onSubmit={handleSubmit}>
      {server.auth_url && (
        <a
          class={styles.authLink}
          href={server.auth_url}
          target="_blank"
          rel="noopener noreferrer"
        >
          Open auth URL ↗
        </a>
      )}
      <div class={styles.authRow}>
        <input
          ref={inputRef}
          class={styles.authInput}
          type="password"
          placeholder={server.auth_url ? 'Paste token/code…' : 'API key or token…'}
          value={value}
          onInput={(e) => setValue(e.target.value)}
          disabled={submitting}
        />
        <Button size="sm" variant="primary" type="submit" loading={submitting}>
          Authenticate
        </Button>
        <Button size="sm" variant="ghost" type="button" onClick={onDone}>
          Cancel
        </Button>
      </div>
      {authError && <span class={styles.authError}>{authError}</span>}
    </form>
  )
}

// ---------------------------------------------------------------------------
// ToolList — collapsible list of tools for a server
// ---------------------------------------------------------------------------

const ToolList = ({ tools }) => {
  if (!tools || tools.length === 0) {
    return <div class={styles.noTools}>No tools registered</div>
  }

  return (
    <ul class={styles.toolList}>
      {tools.map((tool) => (
        <li key={tool.name} class={styles.toolItem}>
          <span class={styles.toolName}>{tool.name}</span>
          {tool.description && (
            <span class={styles.toolDesc}>{tool.description}</span>
          )}
        </li>
      ))}
    </ul>
  )
}

// ---------------------------------------------------------------------------
// McpServerCard — one card per MCP server
// ---------------------------------------------------------------------------

const McpServerCard = ({ server, sessionId, onUpdate }) => {
  const [expanded, setExpanded] = useState(false)
  const [toggling, setToggling] = useState(false)
  const [refreshing, setRefreshing] = useState(false)
  const [clearingAuth, setClearingAuth] = useState(false)
  const [authOpen, setAuthOpen] = useState(false)

  const handleToggle = async () => {
    if (toggling) return
    setToggling(true)
    try {
      await http.post(`/api/sessions/${sessionId}/mcp/toggle`, {
        server_name: server.name,
        enabled: !server.enabled,
      })
      onUpdate()
    } catch (err) {
      console.warn('[mcp] toggle failed:', err.message)
    } finally {
      setToggling(false)
    }
  }

  const handleRefresh = async () => {
    if (refreshing) return
    setRefreshing(true)
    try {
      await http.post(`/api/sessions/${sessionId}/mcp/refresh`, {
        server_name: server.name,
      })
      onUpdate()
    } catch (err) {
      console.warn('[mcp] refresh failed:', err.message)
    } finally {
      setRefreshing(false)
    }
  }

  const handleClearAuth = async () => {
    if (clearingAuth) return
    setClearingAuth(true)
    try {
      await http.post(`/api/sessions/${sessionId}/mcp/clear-auth`, {
        server_name: server.name,
      })
      onUpdate()
    } catch (err) {
      console.warn('[mcp] clear auth failed:', err.message)
    } finally {
      setClearingAuth(false)
    }
  }

  const toolCount = server.tools?.length ?? 0
  const edgeColor = server.status === 'connected'
    ? 'feedback-positive'
    : server.status === 'error'
      ? 'feedback-negative'
      : null

  return (
    <div class={`${styles.serverCard} ${server.enabled ? '' : styles.serverDisabled}`}>
      {edgeColor && (
        <div
          class={styles.edgeBar}
          style={{ '--edge-color': `var(--color-${edgeColor})` }}
        />
      )}

      <div class={styles.serverMain}>
        {/* Header row */}
        <div class={styles.serverHeader}>
          <button
            class={styles.expandBtn}
            onClick={() => setExpanded((v) => !v)}
            aria-expanded={expanded}
            aria-label={expanded ? 'Collapse tools' : 'Expand tools'}
          >
            <span class={styles.expandIcon}>{expanded ? '▼' : '▶'}</span>
            <span class={styles.serverName}>{server.name}</span>
            {toolCount > 0 && (
              <span class={styles.toolCountBadge}>{toolCount}</span>
            )}
          </button>

          <div class={styles.serverMeta}>
            <Badge
              variant="status"
              color={serverStatusColor(server.status)}
            >
              {serverStatusLabel(server.status)}
            </Badge>

            {server.auth_required && !server.authenticated && (
              <Badge variant="status" color="feedback-caution">
                auth required
              </Badge>
            )}
            {server.authenticated && (
              <Badge variant="status" color="feedback-positive">
                authenticated
              </Badge>
            )}
          </div>
        </div>

        {/* Action row */}
        <div class={styles.serverActions}>
          <button
            class={`${styles.toggleSwitch} ${server.enabled ? styles.toggleOn : ''}`}
            onClick={handleToggle}
            disabled={toggling}
            aria-label={server.enabled ? `Disable ${server.name}` : `Enable ${server.name}`}
            aria-checked={server.enabled}
            role="switch"
          >
            {toggling && <Spinner size="sm" />}
          </button>

          <Button
            size="sm"
            variant="ghost"
            loading={refreshing}
            onClick={handleRefresh}
          >
            Refresh
          </Button>

          {server.auth_required && !server.authenticated && !authOpen && (
            <Button
              size="sm"
              variant="ghost"
              onClick={() => setAuthOpen(true)}
            >
              Authenticate
            </Button>
          )}

          {server.authenticated && (
            <Button
              size="sm"
              variant="ghost"
              loading={clearingAuth}
              onClick={handleClearAuth}
            >
              Clear Auth
            </Button>
          )}
        </div>

        {/* Inline auth form */}
        {authOpen && (
          <AuthFlow
            server={server}
            sessionId={sessionId}
            onDone={() => { setAuthOpen(false); onUpdate() }}
          />
        )}

        {/* Tool list */}
        {expanded && (
          <div class={styles.toolsArea}>
            <ToolList tools={server.tools} />
          </div>
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// McpPanel
// ---------------------------------------------------------------------------

const McpPanel = ({ sessionId, liveMcpTools }) => {
  const [servers, setServers] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const fetchTools = () => {
    if (!sessionId) return
    http.get(`/api/sessions/${sessionId}/mcp/tools`)
      .then((data) => {
        setServers(data?.servers || data || [])
        setError(null)
      })
      .catch((err) => {
        setError(err.message)
      })
      .finally(() => {
        setLoading(false)
      })
  }

  useEffect(() => {
    setLoading(true)
    fetchTools()
  }, [sessionId])

  // Apply live WS updates (mcp_tools_list event)
  useEffect(() => {
    if (!liveMcpTools) return
    setServers(liveMcpTools?.servers || liveMcpTools || [])
  }, [liveMcpTools])

  return (
    <div class={styles.panel}>
      <div class={styles.header}>
        <span class={styles.headerTitle}>MCP Servers</span>
        {servers.length > 0 && (
          <span class={styles.headerCount}>{servers.length}</span>
        )}
      </div>

      {loading && (
        <div class={styles.center}>
          <Spinner size="md" />
        </div>
      )}

      {!loading && error && (
        <div class={styles.errorMsg}>{error}</div>
      )}

      {!loading && !error && servers.length === 0 && (
        <div class={styles.emptyMsg}>No MCP servers configured for this session.</div>
      )}

      {!loading && servers.length > 0 && (
        <div class={styles.serverList}>
          {servers.map((server) => (
            <McpServerCard
              key={server.name}
              server={server}
              sessionId={sessionId}
              onUpdate={fetchTools}
            />
          ))}
        </div>
      )}
    </div>
  )
}

export { McpPanel }
