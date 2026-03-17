import { useState, useEffect } from 'preact/hooks'
import { http } from '../stores/connection.js'
import { Card } from '../components/ui/card.jsx'
import { Badge } from '../components/ui/badge.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import { useLocation } from 'wouter-preact'
import styles from './missions.module.css'

const STATUS_COLORS = {
  polling: 'status-working',
  idle: 'status-reply',
  paused: 'status-ended',
  stopped: 'status-ended',
  error: 'feedback-negative',
}

const MissionsPage = () => {
  const [missions, setMissions] = useState([])
  const [loading, setLoading] = useState(true)
  const [, navigate] = useLocation()

  useEffect(() => {
    const load = async () => {
      try {
        const data = await http.get('/api/missions')
        setMissions(data.missions || [])
      } catch (err) {
        console.warn('[missions] failed to load:', err.message)
      } finally {
        setLoading(false)
      }
    }
    load()
  }, [])

  if (loading) {
    return <div class={styles.page}><div class={styles.loading}><Spinner size="lg" /></div></div>
  }

  return (
    <div class={styles.page}>
      <div class={styles.header}>
        <h1 class={styles.title}>Missions</h1>
      </div>
      {missions.length === 0 ? (
        <div class={styles.empty}>No missions configured</div>
      ) : (
        <div class={styles.list}>
          {missions.map((m) => (
            <button key={m.id} class={styles.missionCard} onClick={() => navigate(`/missions/${m.id}`)}>
              <Card>
                <div class={styles.missionHeader}>
                  <div class={styles.missionInfo}>
                    <span class={styles.missionName}>{m.name || m.id}</span>
                    <Badge variant="tool" color={`provider-${m.provider || 'claude'}`}>
                      {m.provider || 'claude'}
                    </Badge>
                    {m.orchestrator_status && (
                      <Badge variant="status" color={STATUS_COLORS[m.orchestrator_status] || 'status-ended'}>
                        {m.orchestrator_status}
                      </Badge>
                    )}
                  </div>
                  <div class={styles.missionCounts}>
                    {m.active_count > 0 && <span class={styles.countActive}>{m.active_count} active</span>}
                    {m.queued_count > 0 && <span class={styles.countQueued}>{m.queued_count} queued</span>}
                    <span class={styles.countDone}>{m.completed_count || 0} done</span>
                    {m.failed_count > 0 && <span class={styles.countFailed}>{m.failed_count} failed</span>}
                  </div>
                </div>
                {m.repo_root && <div class={styles.missionRepo}>{m.repo_root}</div>}
                {m.parse_error && <div class={styles.missionError}>{m.parse_error}</div>}
              </Card>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

export { MissionsPage }
