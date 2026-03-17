import { useState, useEffect } from 'preact/hooks'
import { useRoute } from 'wouter-preact'
import { http } from '../stores/connection.js'
import { Card } from '../components/ui/card.jsx'
import { Badge } from '../components/ui/badge.jsx'
import { Button } from '../components/ui/button.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import styles from './mission-detail.module.css'

const STATE_COLORS = {
  queued: 'text-secondary',
  claimed: 'status-working',
  running: 'status-working',
  retry_queued: 'feedback-caution',
  completed: 'feedback-positive',
  failed: 'feedback-negative',
  blocked: 'feedback-warning',
}

const MissionDetailPage = () => {
  const [, params] = useRoute('/missions/:id')
  const missionId = params?.id
  const [detail, setDetail] = useState(null)
  const [loading, setLoading] = useState(true)

  const load = async () => {
    try {
      const data = await http.get(`/api/missions/${missionId}`)
      setDetail(data)
    } catch (err) {
      console.warn('[mission] failed to load:', err.message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (missionId) load()
  }, [missionId])

  if (loading) {
    return <div class={styles.page}><div class={styles.loading}><Spinner size="lg" /></div></div>
  }

  if (!detail) {
    return <div class={styles.page}><div class={styles.empty}>Mission not found</div></div>
  }

  const { summary, issues, settings } = detail

  const handlePause = () => http.put(`/api/missions/${missionId}`, { paused: !summary.paused }).then(load)
  const handleStartOrchestrator = () => http.post(`/api/missions/${missionId}/start-orchestrator`).then(load)

  return (
    <div class={styles.page}>
      <div class={styles.header}>
        <div class={styles.headerInfo}>
          <h1 class={styles.title}>{summary.name || missionId}</h1>
          <Badge variant="tool" color={`provider-${summary.provider || 'claude'}`}>
            {summary.provider || 'claude'}
          </Badge>
          {summary.orchestrator_status && (
            <Badge variant="status">{summary.orchestrator_status}</Badge>
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

      {summary.repo_root && (
        <div class={styles.repo}>{summary.repo_root}</div>
      )}

      <section class={styles.section}>
        <h2 class={styles.sectionTitle}>Issues ({issues?.length || 0})</h2>
        {(!issues || issues.length === 0) ? (
          <div class={styles.empty}>No issues</div>
        ) : (
          <div class={styles.issueList}>
            {issues.map((issue) => (
              <Card key={issue.issue_id}>
                <div class={styles.issueRow}>
                  <div class={styles.issueInfo}>
                    <Badge variant="tool">{issue.identifier}</Badge>
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
                      <span class={styles.attempt}>attempt {issue.attempt}</span>
                    )}
                  </div>
                </div>
                {issue.error && <div class={styles.issueError}>{issue.error}</div>}
                {issue.orchestration_state === 'failed' && (
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => http.post(`/api/missions/${missionId}/issues/${issue.issue_id}/retry`).then(load)}
                  >
                    Retry
                  </Button>
                )}
              </Card>
            ))}
          </div>
        )}
      </section>

      {settings && (
        <section class={styles.section}>
          <h2 class={styles.sectionTitle}>Settings</h2>
          <Card>
            <pre class={styles.settingsJson}>{JSON.stringify(settings, null, 2)}</pre>
          </Card>
        </section>
      )}
    </div>
  )
}

export { MissionDetailPage }
