import { useState, useEffect } from 'preact/hooks'
import { useRoute, useLocation } from 'wouter-preact'
import { http } from '../stores/connection.js'
import { Card } from '../components/ui/card.jsx'
import { Badge } from '../components/ui/badge.jsx'
import { Button } from '../components/ui/button.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import { TabBar } from '../components/ui/tab-bar.jsx'
import { SegmentedControl } from '../components/input/provider-controls.jsx'
import styles from './mission-detail.module.css'

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const STATE_COLORS = {
  queued:       'text-secondary',
  claimed:      'status-working',
  running:      'status-working',
  retry_queued: 'feedback-caution',
  completed:    'feedback-positive',
  failed:       'feedback-negative',
  blocked:      'feedback-warning',
}

const ORCHESTRATOR_STATUS_COLORS = {
  polling: 'status-working',
  idle:    'status-reply',
  paused:  'status-ended',
  stopped: 'status-ended',
  error:   'feedback-negative',
}

const PROVIDER_OPTIONS = [
  { value: 'claude', label: 'Claude' },
  { value: 'codex',  label: 'Codex'  },
]

const ISSUE_FILTERS = [
  { id: 'all',       label: 'All'       },
  { id: 'active',    label: 'Active'    },
  { id: 'completed', label: 'Completed' },
  { id: 'failed',    label: 'Failed'    },
]

const ACTIVE_STATES  = new Set(['claimed', 'running', 'retry_queued'])
const FAILED_STATES  = new Set(['failed', 'blocked'])

// ---------------------------------------------------------------------------
// Linear API key banner
// ---------------------------------------------------------------------------

const LinearKeyBanner = () => {
  const [, navigate] = useLocation()
  return (
    <div class={styles.linearBanner}>
      <span class={styles.linearBannerText}>Linear API key not configured</span>
      <button class={styles.linearBannerLink} onClick={() => navigate('/settings')}>
        Go to Settings
      </button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Overview tab
// ---------------------------------------------------------------------------

const OverviewTab = ({ summary, missionId, onReload }) => {
  const [switchingProvider, setSwitchingProvider] = useState(false)

  const handleProviderChange = async (provider) => {
    if (provider === summary.provider) return
    setSwitchingProvider(true)
    try {
      await http.put(`/api/missions/${missionId}`, { provider })
      await onReload()
    } catch (err) {
      console.warn('[mission] provider change failed:', err.message)
    } finally {
      setSwitchingProvider(false)
    }
  }

  const activeCount    = summary.active_count    ?? 0
  const queuedCount    = summary.queued_count    ?? 0
  const completedCount = summary.completed_count ?? 0
  const failedCount    = summary.failed_count    ?? 0

  const threads = summary.threads ?? summary.active_threads ?? []

  return (
    <div class={styles.tabContent}>
      {/* Summary card */}
      <Card>
        <div class={styles.overviewGrid}>
          <div class={styles.overviewRow}>
            <span class={styles.overviewLabel}>Provider</span>
            <div class={styles.overviewValue}>
              <SegmentedControl
                options={PROVIDER_OPTIONS}
                value={summary.provider || 'claude'}
                onChange={handleProviderChange}
                colorVar={`var(--color-provider-${summary.provider || 'claude'})`}
              />
              {switchingProvider && <Spinner size="sm" />}
            </div>
          </div>

          {summary.orchestrator_status && (
            <div class={styles.overviewRow}>
              <span class={styles.overviewLabel}>Orchestrator</span>
              <Badge
                variant="status"
                color={ORCHESTRATOR_STATUS_COLORS[summary.orchestrator_status] || 'text-tertiary'}
              >
                {summary.orchestrator_status}
              </Badge>
            </div>
          )}

          {summary.repo_root && (
            <div class={styles.overviewRow}>
              <span class={styles.overviewLabel}>Repo</span>
              <span class={styles.overviewMono}>{summary.repo_root}</span>
            </div>
          )}
        </div>
      </Card>

      {/* Issue count badges */}
      <div class={styles.countRow}>
        {activeCount > 0 && (
          <div class={styles.countBadge} data-color="working">
            <span class={styles.countNum}>{activeCount}</span>
            <span class={styles.countLabel}>active</span>
          </div>
        )}
        {queuedCount > 0 && (
          <div class={styles.countBadge} data-color="queued">
            <span class={styles.countNum}>{queuedCount}</span>
            <span class={styles.countLabel}>queued</span>
          </div>
        )}
        <div class={styles.countBadge} data-color="done">
          <span class={styles.countNum}>{completedCount}</span>
          <span class={styles.countLabel}>completed</span>
        </div>
        {failedCount > 0 && (
          <div class={styles.countBadge} data-color="failed">
            <span class={styles.countNum}>{failedCount}</span>
            <span class={styles.countLabel}>failed</span>
          </div>
        )}
      </div>

      {/* Active threads */}
      <section>
        <h2 class={styles.sectionTitle}>Active Threads</h2>
        {threads.length === 0 ? (
          <div class={styles.emptySection}>No active threads</div>
        ) : (
          <div class={styles.threadList}>
            {threads.map((thread, i) => (
              <Card key={thread.id ?? i}>
                <div class={styles.threadRow}>
                  <span class={styles.threadName}>{thread.name ?? thread.id ?? `Thread ${i + 1}`}</span>
                  {thread.status && (
                    <Badge variant="status" color={STATE_COLORS[thread.status] || 'text-tertiary'}>
                      {thread.status}
                    </Badge>
                  )}
                </div>
              </Card>
            ))}
          </div>
        )}
      </section>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Issues tab
// ---------------------------------------------------------------------------

const issueEdgeColor = (state) => {
  if (state === 'failed' || state === 'blocked') return 'feedback-negative'
  if (state === 'completed')                     return 'feedback-positive'
  if (state === 'running'  || state === 'claimed') return 'status-working'
  return undefined
}

const IssueCard = ({ issue, missionId, onReload }) => {
  const [expanded, setExpanded] = useState(false)
  const [retrying, setRetrying] = useState(false)
  const [, navigate] = useLocation()

  const handleRetry = async (e) => {
    e.stopPropagation()
    setRetrying(true)
    try {
      await http.post(`/api/missions/${missionId}/issues/${issue.issue_id}/retry`)
      await onReload()
    } catch (err) {
      console.warn('[mission] retry failed:', err.message)
    } finally {
      setRetrying(false)
    }
  }

  const handleCardClick = () => {
    if (issue.session_id) {
      navigate(`/session/${issue.session_id}`)
    } else {
      setExpanded((prev) => !prev)
    }
  }

  const canExpand = !!issue.error || !!issue.session_id

  return (
    <Card edgeColor={issueEdgeColor(issue.orchestration_state)}>
      <div
        class={`${styles.issueCard} ${canExpand ? styles.issueCardClickable : ''}`}
        onClick={canExpand ? handleCardClick : undefined}
        role={canExpand ? 'button' : undefined}
        tabIndex={canExpand ? 0 : undefined}
        onKeyDown={canExpand ? (e) => { if (e.key === 'Enter' || e.key === ' ') handleCardClick() } : undefined}
      >
        <div class={styles.issueRow}>
          <div class={styles.issueInfo}>
            {issue.identifier && (
              <Badge variant="tool">{issue.identifier}</Badge>
            )}
            <span class={styles.issueTitle}>{issue.title}</span>
          </div>
          <div class={styles.issueMeta}>
            <Badge variant="status" color={STATE_COLORS[issue.orchestration_state] || 'text-tertiary'}>
              {issue.orchestration_state}
            </Badge>
            {issue.provider && (
              <Badge variant="tool" color={`provider-${issue.provider}`}>{issue.provider}</Badge>
            )}
            {issue.attempt > 1 && (
              <span class={styles.attempt}>×{issue.attempt}</span>
            )}
            {canExpand && (
              <span class={`${styles.chevron} ${expanded ? styles.chevronOpen : ''}`} aria-hidden="true">›</span>
            )}
          </div>
        </div>

        {expanded && (
          <div class={styles.issueDetails} onClick={(e) => e.stopPropagation()}>
            {issue.error && (
              <div class={styles.issueError}>{issue.error}</div>
            )}
            {issue.session_id && (
              <div class={styles.issueSessionId}>
                Session: <span class={styles.issueMono}>{issue.session_id}</span>
              </div>
            )}
          </div>
        )}
      </div>

      {(issue.orchestration_state === 'failed' || issue.orchestration_state === 'blocked') && (
        <div class={styles.issueActions}>
          <Button
            variant="ghost"
            size="sm"
            onClick={handleRetry}
            loading={retrying}
            disabled={retrying}
          >
            Retry
          </Button>
        </div>
      )}
    </Card>
  )
}

const IssuesTab = ({ issues, missionId, onReload }) => {
  const [filter, setFilter] = useState('all')

  const filtered = (issues ?? []).filter((issue) => {
    if (filter === 'all')       return true
    if (filter === 'active')    return ACTIVE_STATES.has(issue.orchestration_state)
    if (filter === 'completed') return issue.orchestration_state === 'completed'
    if (filter === 'failed')    return FAILED_STATES.has(issue.orchestration_state)
    return true
  })

  return (
    <div class={styles.tabContent}>
      <div class={styles.issueFilterBar}>
        {ISSUE_FILTERS.map((f) => (
          <button
            key={f.id}
            class={`${styles.filterBtn} ${filter === f.id ? styles.filterBtnActive : ''}`}
            onClick={() => setFilter(f.id)}
          >
            {f.label}
          </button>
        ))}
      </div>

      {filtered.length === 0 ? (
        <div class={styles.emptySection}>
          {filter === 'all' ? 'No issues' : `No ${filter} issues`}
        </div>
      ) : (
        <div class={styles.issueList}>
          {filtered.map((issue) => (
            <IssueCard
              key={issue.issue_id}
              issue={issue}
              missionId={missionId}
              onReload={onReload}
            />
          ))}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Settings tab
// ---------------------------------------------------------------------------

const SettingsTab = ({ settings, missionId, onReload }) => {
  const [prompt, setPrompt] = useState(settings?.prompt ?? '')
  const [saving, setSaving] = useState(false)
  const [saveResult, setSaveResult] = useState(null) // 'ok' | 'error'

  // Keep local prompt in sync if settings reload
  useEffect(() => {
    setPrompt(settings?.prompt ?? '')
  }, [settings?.prompt])

  const handleSave = async () => {
    setSaving(true)
    setSaveResult(null)
    try {
      await http.put(`/api/missions/${missionId}/settings`, {
        ...settings,
        prompt,
      })
      setSaveResult('ok')
      await onReload()
    } catch (err) {
      console.warn('[mission] settings save failed:', err.message)
      setSaveResult('error')
    } finally {
      setSaving(false)
    }
  }

  const promptDirty = prompt !== (settings?.prompt ?? '')

  return (
    <div class={styles.tabContent}>
      {/* Provider strategy (read-only) */}
      {settings?.provider && (
        <Card>
          <div class={styles.settingsSection}>
            <h3 class={styles.settingsFieldLabel}>Provider Strategy</h3>
            <div class={styles.settingsFieldGrid}>
              {settings.provider.strategy && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Strategy</span>
                  <Badge variant="tool">{settings.provider.strategy}</Badge>
                </div>
              )}
              {settings.provider.primary && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Primary</span>
                  <Badge variant="tool" color={`provider-${settings.provider.primary}`}>
                    {settings.provider.primary}
                  </Badge>
                </div>
              )}
              {settings.provider.secondary && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Secondary</span>
                  <Badge variant="tool" color={`provider-${settings.provider.secondary}`}>
                    {settings.provider.secondary}
                  </Badge>
                </div>
              )}
              {settings.provider.max_concurrent != null && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Max Concurrent</span>
                  <span class={styles.settingsVal}>{settings.provider.max_concurrent}</span>
                </div>
              )}
            </div>
          </div>
        </Card>
      )}

      {/* Trigger (read-only) */}
      {settings?.trigger && (
        <Card>
          <div class={styles.settingsSection}>
            <h3 class={styles.settingsFieldLabel}>Trigger</h3>
            <div class={styles.settingsFieldGrid}>
              {settings.trigger.kind && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Kind</span>
                  <Badge variant="tool">{settings.trigger.kind}</Badge>
                </div>
              )}
              {settings.trigger.interval && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Interval</span>
                  <span class={styles.settingsVal}>{settings.trigger.interval}</span>
                </div>
              )}
              {settings.trigger.filters && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Filters</span>
                  <span class={styles.settingsVal}>{JSON.stringify(settings.trigger.filters)}</span>
                </div>
              )}
            </div>
          </div>
        </Card>
      )}

      {/* Orchestration (read-only) */}
      {settings?.orchestration && (
        <Card>
          <div class={styles.settingsSection}>
            <h3 class={styles.settingsFieldLabel}>Orchestration</h3>
            <div class={styles.settingsFieldGrid}>
              {settings.orchestration.max_retries != null && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Max Retries</span>
                  <span class={styles.settingsVal}>{settings.orchestration.max_retries}</span>
                </div>
              )}
              {settings.orchestration.stall_timeout && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Stall Timeout</span>
                  <span class={styles.settingsVal}>{settings.orchestration.stall_timeout}</span>
                </div>
              )}
              {settings.orchestration.base_branch && (
                <div class={styles.settingsRow}>
                  <span class={styles.settingsKey}>Base Branch</span>
                  <span class={`${styles.settingsVal} ${styles.mono}`}>{settings.orchestration.base_branch}</span>
                </div>
              )}
            </div>
          </div>
        </Card>
      )}

      {/* Prompt (editable) */}
      <Card>
        <div class={styles.settingsSection}>
          <h3 class={styles.settingsFieldLabel}>Mission Prompt</h3>
          <textarea
            class={styles.promptTextarea}
            value={prompt}
            onInput={(e) => setPrompt(e.target.value)}
            placeholder="No prompt configured"
            rows={10}
          />
          <div class={styles.saveRow}>
            {saveResult === 'ok' && (
              <span class={styles.saveOk}>Saved</span>
            )}
            {saveResult === 'error' && (
              <span class={styles.saveError}>Save failed</span>
            )}
            <Button
              variant="primary"
              size="sm"
              onClick={handleSave}
              loading={saving}
              disabled={saving || !promptDirty}
            >
              Save
            </Button>
          </div>
        </div>
      </Card>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------

const MissionDetailPage = () => {
  const [, params] = useRoute('/missions/:id')
  const missionId = params?.id
  const [detail, setDetail] = useState(null)
  const [loading, setLoading] = useState(true)
  const [activeTab, setActiveTab] = useState('overview')
  const [linearKeyMissing, setLinearKeyMissing] = useState(false)

  const load = async (showSpinner = false) => {
    if (showSpinner) setLoading(true)
    try {
      const data = await http.get(`/api/missions/${missionId}`)
      setDetail(data)
    } catch (err) {
      console.warn('[mission] failed to load:', err.message)
    } finally {
      if (showSpinner) setLoading(false)
    }
  }

  const checkLinearKey = async () => {
    try {
      const data = await http.get('/api/server/linear-key')
      // If configured is false or key is absent, show banner
      setLinearKeyMissing(!data?.configured)
    } catch {
      // If the endpoint fails we can't be sure — don't show banner
    }
  }

  useEffect(() => {
    if (!missionId) return
    load(true)
    checkLinearKey()
  }, [missionId])

  if (loading) {
    return (
      <div class={styles.page}>
        <div class={styles.loadingState}><Spinner size="lg" /></div>
      </div>
    )
  }

  if (!detail) {
    return (
      <div class={styles.page}>
        <div class={styles.emptyState}>Mission not found</div>
      </div>
    )
  }

  const { summary, issues, settings } = detail

  const handlePause = () =>
    http.put(`/api/missions/${missionId}`, { paused: !summary.paused }).then(load)

  const handleStartOrchestrator = () =>
    http.post(`/api/missions/${missionId}/start-orchestrator`).then(load)

  const totalIssues = issues?.length ?? 0
  const failedCount = (issues ?? []).filter((i) => FAILED_STATES.has(i.orchestration_state)).length

  const tabs = [
    { id: 'overview', label: 'Overview' },
    { id: 'issues',   label: 'Issues',   count: totalIssues },
    { id: 'settings', label: 'Settings' },
  ]

  return (
    <div class={styles.page}>
      {linearKeyMissing && <LinearKeyBanner />}

      {/* Page header */}
      <div class={styles.header}>
        <div class={styles.headerInfo}>
          <h1 class={styles.title}>{summary.name || missionId}</h1>
          <Badge variant="tool" color={`provider-${summary.provider || 'claude'}`}>
            {summary.provider || 'claude'}
          </Badge>
          {summary.orchestrator_status && (
            <Badge
              variant="status"
              color={ORCHESTRATOR_STATUS_COLORS[summary.orchestrator_status] || 'text-tertiary'}
            >
              {summary.orchestrator_status}
            </Badge>
          )}
          {failedCount > 0 && (
            <Badge variant="status" color="feedback-negative">
              {failedCount} failed
            </Badge>
          )}
        </div>
        <div class={styles.headerActions}>
          <Button variant="ghost" size="sm" onClick={handlePause}>
            {summary.paused ? 'Resume' : 'Pause'}
          </Button>
          <Button variant="secondary" size="sm" onClick={handleStartOrchestrator}>
            Start Orchestrator
          </Button>
        </div>
      </div>

      {/* Tab bar */}
      <TabBar tabs={tabs} activeTab={activeTab} onTabChange={setActiveTab} />

      {/* Tab panels */}
      {activeTab === 'overview' && (
        <OverviewTab summary={summary} missionId={missionId} onReload={load} />
      )}
      {activeTab === 'issues' && (
        <IssuesTab issues={issues} missionId={missionId} onReload={load} />
      )}
      {activeTab === 'settings' && (
        <SettingsTab settings={settings} missionId={missionId} onReload={load} />
      )}
    </div>
  )
}

export { MissionDetailPage }
