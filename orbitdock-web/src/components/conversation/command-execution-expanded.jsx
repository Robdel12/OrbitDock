import { useEffect, useState } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import { Spinner } from '../ui/spinner.jsx'
import styles from './tool-expanded.module.css'

const actionDetail = (action) => {
  return action.name || action.query || action.path || action.command || action.type.replace('_', ' ')
}

const CommandExecutionExpanded = ({ sessionId, rowId, row }) => {
  const [content, setContent] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    let cancelled = false

    const load = async () => {
      try {
        const data = await http.get(`/api/sessions/${sessionId}/rows/${rowId}/content`)
        if (!cancelled) setContent(data)
      } catch (err) {
        if (!cancelled) setError(err.message)
      } finally {
        if (!cancelled) setLoading(false)
      }
    }

    load()
    return () => {
      cancelled = true
    }
  }, [sessionId, rowId])

  if (loading) {
    return (
      <div class={styles.loading}>
        <Spinner size="sm" />
      </div>
    )
  }

  if (error) {
    return <div class={styles.error}>{error}</div>
  }

  const output = content?.output_display || row.aggregated_output || row.live_output_preview

  return (
    <div class={styles.expanded}>
      <div class={styles.section}>
        <div class={styles.sectionLabel}>Command</div>
        <pre class={styles.code}>{row.command}</pre>
      </div>

      {row.cwd && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Working Directory</div>
          <pre class={styles.code}>{row.cwd}</pre>
        </div>
      )}

      {row.process_id && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Process</div>
          <pre class={styles.code}>{row.process_id}</pre>
        </div>
      )}

      {row.command_actions?.length > 0 && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Actions</div>
          <pre class={styles.code}>
            {row.command_actions
              .map((action) => `${action.type.replace('_', ' ')}: ${actionDetail(action)}`)
              .join('\n')}
          </pre>
        </div>
      )}

      {output && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Output</div>
          <pre class={styles.code}>{output}</pre>
        </div>
      )}

      {!output && row.status === 'in_progress' && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Output</div>
          <pre class={styles.code}>Waiting for command output…</pre>
        </div>
      )}
    </div>
  )
}

export { CommandExecutionExpanded }
