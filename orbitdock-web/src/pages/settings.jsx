import { useState, useEffect } from 'preact/hooks'
import { connectionState, serverInfo, http } from '../stores/connection.js'
import { Button } from '../components/ui/button.jsx'
import { Card } from '../components/ui/card.jsx'
import { Badge } from '../components/ui/badge.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import styles from './settings.module.css'

const SettingsPage = () => {
  const [claudeModels, setClaudeModels] = useState([])
  const [codexModels, setCodexModels] = useState([])
  const [claudeUsage, setClaudeUsage] = useState(null)
  const [codexUsage, setCodexUsage] = useState(null)
  const [openAiKey, setOpenAiKey] = useState(null)
  const [linearKey, setLinearKey] = useState(null)
  const [loading, setLoading] = useState(true)

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

  if (loading) {
    return (
      <div class={styles.page}>
        <div class={styles.loading}><Spinner size="lg" /></div>
      </div>
    )
  }

  const connState = connectionState.value
  const info = serverInfo.value

  return (
    <div class={styles.page}>
      <h1 class={styles.title}>Settings</h1>

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
            <span class={styles.label}>Server</span>
            <span class={styles.value}>localhost:4000</span>
          </div>
          <div class={styles.row}>
            <span class={styles.label}>Primary</span>
            <span class={styles.value}>{info.isPrimary ? 'Yes' : 'No'}</span>
          </div>
        </Card>
      </section>

      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>API Keys</h2>
        <Card>
          <div class={styles.row}>
            <span class={styles.label}>OpenAI Key</span>
            <Badge variant={openAiKey?.configured ? 'status' : 'meta'} color={openAiKey?.configured ? 'feedback-positive' : 'feedback-negative'}>
              {openAiKey?.configured ? 'Configured' : 'Not Set'}
            </Badge>
          </div>
          <div class={styles.row}>
            <span class={styles.label}>Linear Key</span>
            <Badge variant={linearKey?.configured ? 'status' : 'meta'} color={linearKey?.configured ? 'feedback-positive' : 'feedback-negative'}>
              {linearKey?.configured ? 'Configured' : 'Not Set'}
            </Badge>
          </div>
        </Card>
      </section>

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
    </div>
  )
}

const UsageCard = ({ provider, usage }) => (
  <Card edgeColor={`provider-${provider}`}>
    <div class={styles.usageHeader}>
      <Badge variant="status" color={`provider-${provider}`}>{provider}</Badge>
    </div>
    <pre class={styles.usageData}>{JSON.stringify(usage, null, 2)}</pre>
  </Card>
)

export { SettingsPage }
