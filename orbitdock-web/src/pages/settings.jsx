import { useState, useEffect } from 'preact/hooks'
import { connectionState, serverInfo, http, connect, disconnect } from '../stores/connection.js'
import { sessions } from '../stores/sessions.js'
import { Button } from '../components/ui/button.jsx'
import { Card } from '../components/ui/card.jsx'
import { Badge } from '../components/ui/badge.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import { UsageGauge } from '../components/ui/usage-gauge.jsx'
import { ApiKeyInput } from '../components/settings/api-key-input.jsx'
import styles from './settings.module.css'

// Derive the WebSocket URL the same way main.jsx does on startup.
const wsUrl = () =>
  `${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/ws`

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

const SettingsPage = () => {
  const [claudeModels, setClaudeModels] = useState([])
  const [codexModels, setCodexModels] = useState([])
  const [claudeUsage, setClaudeUsage] = useState(null)
  const [codexUsage, setCodexUsage] = useState(null)
  const [openAiKey, setOpenAiKey] = useState(null)
  const [linearKey, setLinearKey] = useState(null)
  const [loading, setLoading] = useState(true)
  const [reconnecting, setReconnecting] = useState(false)
  const [diagOpen, setDiagOpen] = useState(false)

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
    disconnect()
    connect(wsUrl())
    // Clear the spinner once the machine reaches a stable non-transitional state.
    // Subscribe after connect() so we don't immediately fire on the current state.
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
        <div class={styles.loading}><Spinner size="lg" /></div>
      </div>
    )
  }

  const connState = connectionState.value
  const info = serverInfo.value
  const sessionCount = sessions.value.size

  return (
    <div class={styles.page}>
      <h1 class={styles.title}>Settings</h1>

      {/* Connection */}
      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>Connection</h2>
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
            <Button
              variant="secondary"
              size="sm"
              onClick={handleReconnect}
              loading={reconnecting}
              disabled={reconnecting}
            >
              Reconnect
            </Button>
          </div>
        </Card>
      </section>

      {/* API Keys */}
      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>API Keys</h2>
        <Card>
          <ApiKeyInput
            label="OpenAI Key"
            currentValue={openAiKey}
            onSave={handleSaveOpenAiKey}
            validate={validateOpenAiKey}
            placeholder="sk-..."
          />
          <ApiKeyInput
            label="Linear Key"
            currentValue={linearKey}
            onSave={handleSaveLinearKey}
            validate={validateLinearKey}
            placeholder="lin_api_..."
          />
        </Card>
      </section>

      {/* Preferences */}
      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>Preferences</h2>
        <Card>
          <div class={styles.preferenceRow}>
            <div>
              <div class={styles.preferenceLabel}>Theme</div>
              <div class={styles.preferenceHint}>Light theme coming soon</div>
            </div>
            <div class={styles.preferenceControl}>
              <Badge variant="status" color="accent">Dark</Badge>
            </div>
          </div>
        </Card>
      </section>

      {/* Claude Models */}
      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>Claude Models</h2>
        {claudeModels.length > 0 ? (
          <div class={styles.modelGrid}>
            {claudeModels.map((m) => (
              <Card key={m.value} edgeColor="provider-claude">
                <div class={styles.modelName}>{m.display_name || m.value}</div>
                {m.description && <div class={styles.modelDesc}>{m.description}</div>}
                <Badge variant="tool" color="provider-claude">{m.value}</Badge>
              </Card>
            ))}
          </div>
        ) : (
          <div class={styles.empty}>No Claude models available</div>
        )}
      </section>

      {/* Codex Models */}
      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>Codex Models</h2>
        {codexModels.length > 0 ? (
          <div class={styles.modelGrid}>
            {codexModels.map((m) => (
              <Card key={m.id || m.model} edgeColor="provider-codex">
                <div class={styles.modelName}>{m.display_name || m.model}</div>
                {m.description && <div class={styles.modelDesc}>{m.description}</div>}
                <Badge variant="tool" color="provider-codex">{m.model || m.id}</Badge>
              </Card>
            ))}
          </div>
        ) : (
          <div class={styles.empty}>No Codex models available</div>
        )}
      </section>

      {/* Usage */}
      {(claudeUsage || codexUsage) && (
        <section class={styles.section}>
          <h2 class={styles.sectionTitle}>Usage</h2>
          <div class={styles.usageGrid}>
            {claudeUsage?.usage && (
              <UsageCard provider="claude" usage={claudeUsage.usage} />
            )}
            {codexUsage?.usage && (
              <UsageCard provider="codex" usage={codexUsage.usage} />
            )}
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
        </section>
      )}

      {/* Diagnostics */}
      <section class={styles.section}>
        <button
          class={styles.diagnosticsTrigger}
          onClick={() => setDiagOpen((prev) => !prev)}
          aria-expanded={diagOpen}
        >
          <span class={`${styles.diagnosticsChevron} ${diagOpen ? styles.diagnosticsChevronOpen : ''}`}>
            &#9658;
          </span>
          Diagnostics
        </button>
        {diagOpen && (
          <div class={styles.diagnosticsBody}>
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
        )}
      </section>
    </div>
  )
}

const UsageCard = ({ provider, usage }) => {
  const label = provider.charAt(0).toUpperCase() + provider.slice(1)
  const windows = usage?.windows ?? []

  return (
    <Card edgeColor={`provider-${provider}`}>
      <div class={styles.usageHeader}>
        <Badge variant="status" color={`provider-${provider}`}>{label}</Badge>
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
