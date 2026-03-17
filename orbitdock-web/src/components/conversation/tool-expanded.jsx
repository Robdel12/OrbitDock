import { useState, useEffect } from 'preact/hooks'
import { DiffView } from './diff-view.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './tool-expanded.module.css'

const ToolExpanded = ({ sessionId, rowId, http, outputPreview, diffPreview }) => {
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
    return () => { cancelled = true }
  }, [sessionId, rowId])

  if (loading) {
    return <div class={styles.loading}><Spinner size="sm" /></div>
  }

  if (error) {
    return <div class={styles.error}>{error}</div>
  }

  const data = content || {}

  return (
    <div class={styles.expanded}>
      {data.input_display && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Input</div>
          <pre class={styles.code}>{data.input_display}</pre>
        </div>
      )}
      {data.output_display && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Output</div>
          <pre class={styles.code}>{data.output_display}</pre>
        </div>
      )}
      {data.diff_display && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Diff</div>
          <DiffView lines={data.diff_display} />
        </div>
      )}
      {!data.input_display && !data.output_display && !data.diff_display && outputPreview && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Output</div>
          <pre class={styles.code}>{outputPreview}</pre>
        </div>
      )}
    </div>
  )
}

export { ToolExpanded }
