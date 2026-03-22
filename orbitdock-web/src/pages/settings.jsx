import { useEffect, useState } from 'preact/hooks'
import { ApiKeyInput } from '../components/settings/api-key-input.jsx'
import { Badge } from '../components/ui/badge.jsx'
import { Button } from '../components/ui/button.jsx'
import { Card } from '../components/ui/card.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import { UsageGauge } from '../components/ui/usage-gauge.jsx'
import { token as authToken, clearToken } from '../stores/auth.js'
import { authRequired, connectionState, http, reconnect, serverInfo } from '../stores/connection.js'
import { sessions } from '../stores/sessions.js'
import styles from './settings.module.css'

const wsUrl = () => `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`

const validateOpenAiKey = (value) => {
  if (!value.startsWith('sk-')) return 'Key must start with "sk-"'
  if (value.length < 20) return 'Key is too short'
  return null
}

const validateLinearKey = (value) => {
  if (!value.startsWith('lin_api_')) return 'Key must start with "lin_api_"'
  if (value.length < 10) return 'Key is too short'
  return null
}

// ── Sidebar pane definitions ────────────────────────────────────────────────

const PANES = [
  { id: 'connection', label: 'Connection', icon: ConnectionIcon },
  { id: 'api-keys', label: 'API Keys', icon: KeyIcon },
  { id: 'models', label: 'Models', icon: ModelsIcon },
  { id: 'usage', label: 'Usage', icon: UsageIcon },
  { id: 'preferences', label: 'Preferences', icon: PrefsIcon },
  { id: 'notifications', label: 'Notifications', icon: BellIcon },
  { id: 'diagnostics', label: 'Diagnostics', icon: DiagIcon },
]

// ── SVG icons (14×14) ───────────────────────────────────────────────────────

function ConnectionIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M5 12.55a11 11 0 0114.08 0" />
      <path d="M1.42 9a16 16 0 0121.16 0" />
      <path d="M8.53 16.11a6 6 0 016.95 0" />
      <circle cx="12" cy="20" r="1" />
    </svg>
  )
}

function KeyIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M21 2l-2 2m-7.61 7.61a5.5 5.5 0 11-7.778 7.778 5.5 5.5 0 017.777-7.777zm0 0L15.5 7.5m0 0l3 3L22 7l-3-3m-3.5 3.5L19 4" />
    </svg>
  )
}

function ModelsIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <rect x="4" y="4" width="16" height="16" rx="2" />
      <path d="M9 9h6M9 13h6M9 17h4" />
    </svg>
  )
}

function UsageIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M12 20V10M18 20V4M6 20v-4" />
    </svg>
  )
}

function PrefsIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 00.33 1.82l.06.06a2 2 0 01-2.83 2.83l-.06-.06a1.65 1.65 0 00-1.82-.33 1.65 1.65 0 00-1 1.51V21a2 2 0 01-4 0v-.09a1.65 1.65 0 00-1.08-1.51 1.65 1.65 0 00-1.82.33l-.06.06a2 2 0 01-2.83-2.83l.06-.06a1.65 1.65 0 00.33-1.82 1.65 1.65 0 00-1.51-1H3a2 2 0 010-4h.09a1.65 1.65 0 001.51-1.08 1.65 1.65 0 00-.33-1.82l-.06-.06a2 2 0 012.83-2.83l.06.06a1.65 1.65 0 001.82.33H9a1.65 1.65 0 001-1.51V3a2 2 0 014 0v.09a1.65 1.65 0 001.08 1.51 1.65 1.65 0 001.82-.33l.06-.06a2 2 0 012.83 2.83l-.06.06a1.65 1.65 0 00-.33 1.82V9c.26.604.852.997 1.51 1H21a2 2 0 010 4h-.09a1.65 1.65 0 00-1.51 1.08z" />
    </svg>
  )
}

function BellIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M18 8A6 6 0 006 8c0 7-3 9-3 9h18s-3-2-3-9" />
      <path d="M13.73 21a2 2 0 01-3.46 0" />
    </svg>
  )
}

function DiagIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z" />
      <path d="M14 2v6h6M16 13H8M16 17H8M10 9H8" />
    </svg>
  )
}

// ── Main settings page ──────────────────────────────────────────────────────

const SettingsPage = () => {
  const [pane, setPane] = useState('connection')
  const [claudeModels, setClaudeModels] = useState([])
  const [codexModels, setCodexModels] = useState([])
  const [claudeUsage, setClaudeUsage] = useState(null)
  const [codexUsage, setCodexUsage] = useState(null)
  const [openAiKey, setOpenAiKey] = useState(null)
  const [linearKey, setLinearKey] = useState(null)
  const [loading, setLoading] = useState(true)
  const [reconnecting, setReconnecting] = useState(false)

  useEffect(() => {
    const load = async () => {
      try {
        const [cm, xm, cu, xu, ok, lk] = await Promise.allSettled([
          http.get('/api/models/claude'),
          http.get('/api/models/codex'),
          http.get('/api/usage/claude'),
          http.get('/api/usage/codex'),
          http.get('/api/server/openai-key'),
          http.get('/api/server/linear-key'),
        ])
        if (cm.status === 'fulfilled') setClaudeModels(cm.value.models || [])
        if (xm.status === 'fulfilled') setCodexModels(xm.value.models || [])
        if (cu.status === 'fulfilled') setClaudeUsage(cu.value)
        if (xu.status === 'fulfilled') setCodexUsage(xu.value)
        if (ok.status === 'fulfilled') setOpenAiKey(ok.value)
        if (lk.status === 'fulfilled') setLinearKey(lk.value)
      } finally {
        setLoading(false)
      }
    }
    load()
  }, [])

  const handleReconnect = () => {
    setReconnecting(true)
    reconnect()
    const unsub = connectionState.subscribe((state) => {
      if (state === 'connected' || state === 'failed' || state === 'disconnected') {
        setReconnecting(false)
        unsub()
      }
    })
  }

  const handleSaveOpenAiKey = async (key) => {
    await http.put('/api/server/openai-key', { key })
    const updated = await http.get('/api/server/openai-key')
    setOpenAiKey(updated)
  }

  const handleSaveLinearKey = async (key) => {
    await http.put('/api/server/linear-key', { key })
    const updated = await http.get('/api/server/linear-key')
    setLinearKey(updated)
  }

  if (loading) {
    return (
      <div class={styles.page}>
        <div class={styles.loading}>
          <Spinner size="lg" />
        </div>
      </div>
    )
  }

  const connState = connectionState.value
  const info = serverInfo.value
  const sessionCount = sessions.value.size

  return (
    <div class={styles.page}>
      {/* Sidebar — desktop: fixed rail; mobile: horizontal tab chips */}
      <nav class={styles.sidebar}>
        <h1 class={styles.sidebarTitle}>Settings</h1>
        {PANES.map(({ id, label, icon: Icon }) => (
          <button
            key={id}
            class={`${styles.navItem} ${pane === id ? styles.navItemActive : ''}`}
            onClick={() => setPane(id)}
          >
            <Icon />
            <span>{label}</span>
          </button>
        ))}
      </nav>

      {/* Content */}
      <div class={styles.content}>
        {pane === 'connection' && (
          <ConnectionPane connState={connState} info={info} reconnecting={reconnecting} onReconnect={handleReconnect} />
        )}
        {pane === 'api-keys' && (
          <ApiKeysPane
            openAiKey={openAiKey}
            linearKey={linearKey}
            onSaveOpenAi={handleSaveOpenAiKey}
            onSaveLinear={handleSaveLinearKey}
          />
        )}
        {pane === 'models' && <ModelsPane claudeModels={claudeModels} codexModels={codexModels} />}
        {pane === 'usage' && <UsagePane claudeUsage={claudeUsage} codexUsage={codexUsage} />}
        {pane === 'preferences' && <PreferencesPane />}
        {pane === 'notifications' && <NotificationsPane />}
        {pane === 'diagnostics' && <DiagnosticsPane connState={connState} info={info} sessionCount={sessionCount} />}
      </div>
    </div>
  )
}

// ── Individual panes ────────────────────────────────────────────────────────

const PaneHeader = ({ title }) => <h2 class={styles.paneTitle}>{title}</h2>

const ConnectionPane = ({ connState, info, reconnecting, onReconnect }) => (
  <div class={styles.pane}>
    <PaneHeader title="Connection" />
    <Card edgeColor={connState === 'connected' ? 'feedback-positive' : 'feedback-negative'}>
      <div class={styles.row}>
        <span class={styles.label}>Status</span>
        <Badge variant="status" color={connState === 'connected' ? 'feedback-positive' : 'feedback-negative'}>
          {connState}
        </Badge>
      </div>
      <div class={styles.row}>
        <span class={styles.label}>WebSocket URL</span>
        <span class={styles.value}>{wsUrl()}</span>
      </div>
      <div class={styles.row}>
        <span class={styles.label}>Primary</span>
        <span class={styles.value}>{info.isPrimary ? 'Yes' : 'No'}</span>
      </div>
      {info.version && (
        <div class={styles.row}>
          <span class={styles.label}>Server Version</span>
          <span class={styles.value}>{info.version}</span>
        </div>
      )}
      <div class={styles.connectionActions}>
        <Button variant="secondary" size="sm" onClick={onReconnect} loading={reconnecting} disabled={reconnecting}>
          Reconnect
        </Button>
      </div>
    </Card>
  </div>
)

const ApiKeysPane = ({ openAiKey, linearKey, onSaveOpenAi, onSaveLinear }) => (
  <div class={styles.pane}>
    <PaneHeader title="API Keys" />
    <Card>
      <ApiKeyInput
        label="OpenAI Key"
        currentValue={openAiKey}
        onSave={onSaveOpenAi}
        validate={validateOpenAiKey}
        placeholder="sk-..."
      />
      <ApiKeyInput
        label="Linear Key"
        currentValue={linearKey}
        onSave={onSaveLinear}
        validate={validateLinearKey}
        placeholder="lin_api_..."
      />
    </Card>
  </div>
)

const ModelsPane = ({ claudeModels, codexModels }) => (
  <div class={styles.pane}>
    <PaneHeader title="Models" />
    <h3 class={styles.sectionTitle}>Claude</h3>
    {claudeModels.length > 0 ? (
      <div class={styles.modelGrid}>
        {claudeModels.map((m) => (
          <Card key={m.value} edgeColor="provider-claude">
            <div class={styles.modelName}>{m.display_name || m.value}</div>
            {m.description && <div class={styles.modelDesc}>{m.description}</div>}
            <Badge variant="tool" color="provider-claude">
              {m.value}
            </Badge>
          </Card>
        ))}
      </div>
    ) : (
      <div class={styles.empty}>No Claude models available</div>
    )}

    <h3 class={`${styles.sectionTitle} ${styles.sectionTitleSpaced}`}>Codex</h3>
    {codexModels.length > 0 ? (
      <div class={styles.modelGrid}>
        {codexModels.map((m) => (
          <Card key={m.id || m.model} edgeColor="provider-codex">
            <div class={styles.modelName}>{m.display_name || m.model}</div>
            {m.description && <div class={styles.modelDesc}>{m.description}</div>}
            <Badge variant="tool" color="provider-codex">
              {m.model || m.id}
            </Badge>
          </Card>
        ))}
      </div>
    ) : (
      <div class={styles.empty}>No Codex models available</div>
    )}
  </div>
)

const UsagePane = ({ claudeUsage, codexUsage }) => (
  <div class={styles.pane}>
    <PaneHeader title="Usage" />
    {claudeUsage || codexUsage ? (
      <div class={styles.usageGrid}>
        {claudeUsage?.usage && <UsageCard provider="claude" usage={claudeUsage.usage} />}
        {codexUsage?.usage && <UsageCard provider="codex" usage={codexUsage.usage} />}
        {claudeUsage?.error_info && (
          <Card>
            <div class={styles.usageError}>
              <Badge variant="meta">Claude</Badge>
              <span>{claudeUsage.error_info.message}</span>
            </div>
          </Card>
        )}
        {codexUsage?.error_info && (
          <Card>
            <div class={styles.usageError}>
              <Badge variant="meta">Codex</Badge>
              <span>{codexUsage.error_info.message}</span>
            </div>
          </Card>
        )}
      </div>
    ) : (
      <div class={styles.empty}>No usage data available</div>
    )}
  </div>
)

const PreferencesPane = () => {
  const tok = authToken.value
  const masked = tok ? `${tok.slice(0, 8)}${'·'.repeat(12)}${tok.slice(-4)}` : null

  const handleLogout = () => {
    clearToken()
    location.reload()
  }

  return (
    <div class={styles.pane}>
      <PaneHeader title="Preferences" />

      <Card>
        <div class={styles.preferenceRow}>
          <div>
            <div class={styles.preferenceLabel}>Theme</div>
            <div class={styles.preferenceHint}>Light theme coming soon</div>
          </div>
          <div class={styles.preferenceControl}>
            <Badge variant="status" color="accent">
              Dark
            </Badge>
          </div>
        </div>
      </Card>

      {authRequired.value && (
        <>
          <h3 class={`${styles.sectionTitle} ${styles.sectionTitleSpaced}`}>Authentication</h3>
          <Card>
            <div class={styles.preferenceRow}>
              <div>
                <div class={styles.preferenceLabel}>Auth Token</div>
                <div class={styles.preferenceHint}>
                  {masked ? <code class={styles.maskedToken}>{masked}</code> : 'No token set'}
                </div>
              </div>
              <div class={styles.preferenceControl}>
                {tok && (
                  <Button variant="danger" size="sm" onClick={handleLogout}>
                    Log Out
                  </Button>
                )}
              </div>
            </div>
          </Card>
        </>
      )}
    </div>
  )
}

const NotificationsPane = () => {
  const [permission, setPermission] = useState(typeof Notification !== 'undefined' ? Notification.permission : 'denied')
  const [soundEnabled, setSoundEnabled] = useState(() => localStorage.getItem('orbitdock_sound_enabled') !== 'false')

  const handleRequestPermission = async () => {
    if (typeof Notification === 'undefined') return
    const result = await Notification.requestPermission()
    setPermission(result)
  }

  const handleToggleSound = () => {
    const next = !soundEnabled
    setSoundEnabled(next)
    localStorage.setItem('orbitdock_sound_enabled', String(next))
  }

  const notificationsSupported = typeof Notification !== 'undefined'

  return (
    <div class={styles.pane}>
      <PaneHeader title="Notifications" />

      <h3 class={styles.sectionTitle}>Browser Notifications</h3>
      <Card>
        <div class={styles.preferenceRow}>
          <div>
            <div class={styles.preferenceLabel}>Desktop Notifications</div>
            <div class={styles.preferenceHint}>
              {!notificationsSupported
                ? 'Not supported in this browser'
                : permission === 'granted'
                  ? "Enabled — you'll receive alerts when sessions need attention"
                  : permission === 'denied'
                    ? 'Blocked — update your browser site settings to allow notifications'
                    : 'Allow notifications for session alerts'}
            </div>
          </div>
          <div class={styles.preferenceControl}>
            {notificationsSupported && permission === 'granted' && (
              <Badge variant="status" color="feedback-positive">
                Enabled
              </Badge>
            )}
            {notificationsSupported && permission === 'denied' && (
              <Badge variant="status" color="feedback-negative">
                Blocked
              </Badge>
            )}
            {notificationsSupported && permission === 'default' && (
              <Button variant="secondary" size="sm" onClick={handleRequestPermission}>
                Enable
              </Button>
            )}
          </div>
        </div>
      </Card>

      <h3 class={`${styles.sectionTitle} ${styles.sectionTitleSpaced}`}>Sound</h3>
      <Card>
        <div class={styles.preferenceRow}>
          <div>
            <div class={styles.preferenceLabel}>Notification Sounds</div>
            <div class={styles.preferenceHint}>Play a sound when a session needs attention</div>
          </div>
          <div class={styles.preferenceControl}>
            <Button variant={soundEnabled ? 'secondary' : 'ghost'} size="sm" onClick={handleToggleSound}>
              {soundEnabled ? 'On' : 'Off'}
            </Button>
          </div>
        </div>
      </Card>
    </div>
  )
}

const DiagnosticsPane = ({ connState, info, sessionCount }) => (
  <div class={styles.pane}>
    <PaneHeader title="Diagnostics" />
    <Card>
      <div class={styles.diagRow}>
        <span class={styles.diagLabel}>Connection State</span>
        <span class={styles.diagValue}>{connState}</span>
      </div>
      <div class={styles.diagRow}>
        <span class={styles.diagLabel}>WebSocket URL</span>
        <span class={styles.diagValue}>{wsUrl()}</span>
      </div>
      <div class={styles.diagRow}>
        <span class={styles.diagLabel}>Is Primary</span>
        <span class={styles.diagValue}>{String(info.isPrimary)}</span>
      </div>
      {info.version && (
        <div class={styles.diagRow}>
          <span class={styles.diagLabel}>Server Version</span>
          <span class={styles.diagValue}>{info.version}</span>
        </div>
      )}
      <div class={styles.diagRow}>
        <span class={styles.diagLabel}>Active Sessions</span>
        <span class={styles.diagValue}>{sessionCount}</span>
      </div>
      <div class={styles.diagRow}>
        <span class={styles.diagLabel}>Build Mode</span>
        <span class={styles.diagValue}>{import.meta.env.MODE}</span>
      </div>
    </Card>
  </div>
)

const UsageCard = ({ provider, usage }) => {
  const label = provider.charAt(0).toUpperCase() + provider.slice(1)
  const windows = usage?.windows ?? []

  return (
    <Card edgeColor={`provider-${provider}`}>
      <div class={styles.usageHeader}>
        <Badge variant="status" color={`provider-${provider}`}>
          {label}
        </Badge>
      </div>
      {windows.length > 0 ? (
        <div class={styles.gaugeList}>
          {windows.map((w, i) => (
            <UsageGauge
              key={w.name ?? i}
              name={w.name}
              used={w.used}
              limit={w.limit}
              remaining={w.remaining}
              resetsAt={w.resets_at}
            />
          ))}
        </div>
      ) : (
        <div class={styles.empty}>No window data available</div>
      )}
    </Card>
  )
}

export { SettingsPage }
