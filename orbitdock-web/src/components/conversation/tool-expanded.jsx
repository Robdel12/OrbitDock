import { useEffect, useState } from 'preact/hooks'
import { Spinner } from '../ui/spinner.jsx'
import { DiffView } from './diff-view.jsx'
import styles from './tool-expanded.module.css'

// ---------------------------------------------------------------------------
// Guardian Assessment — purpose-built expanded view
// ---------------------------------------------------------------------------

const parseAssessment = (output) => {
  const lines = (output || '').split('\n').filter(Boolean)
  const result = { verdict: null, risk: null, rationale: null }
  for (const line of lines) {
    if (line.startsWith('Verdict:')) result.verdict = line.slice('Verdict:'.length).trim()
    else if (line.startsWith('Risk:')) result.risk = line.slice('Risk:'.length).trim()
    else if (line.startsWith('Rationale:')) result.rationale = line.slice('Rationale:'.length).trim()
  }
  return result
}

const verdictClassName = (verdict) => {
  if (verdict === 'denied' || verdict === 'aborted') return styles.guardianDenied
  if (verdict === 'reviewing') return styles.guardianReviewing
  return styles.guardianApproved
}

const GuardianExpanded = ({ data }) => {
  const { verdict, risk, rationale } = parseAssessment(data.output_display)

  return (
    <div class={styles.expanded}>
      {/* Reviewed action */}
      {data.input_display && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Reviewed Action</div>
          <pre class={styles.code}>{data.input_display}</pre>
        </div>
      )}

      {/* Assessment result */}
      <div class={styles.guardianResult}>
        {verdict && (
          <div class={`${styles.guardianVerdict} ${verdictClassName(verdict)}`}>
            <svg width="12" height="12" viewBox="0 0 12 12" fill="currentColor">
              <path d="M6 0.5L11 3V7C11 9.5 8.8 11 6 11.5C3.2 11 1 9.5 1 7V3L6 0.5Z" />
            </svg>
            <span>{verdict}</span>
          </div>
        )}
        {risk && (
          <div class={styles.guardianMeta}>
            <span class={styles.guardianMetaLabel}>Risk</span>
            <span>{risk}</span>
          </div>
        )}
        {rationale && (
          <div class={styles.guardianMeta}>
            <span class={styles.guardianMetaLabel}>Rationale</span>
            <span>{rationale}</span>
          </div>
        )}
      </div>

      {/* Fallback: if server didn't produce structured output, show raw */}
      {!verdict && !risk && !rationale && data.output_display && (
        <div class={styles.section}>
          <div class={styles.sectionLabel}>Result</div>
          <pre class={styles.code}>{data.output_display}</pre>
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Generic expanded view (default for all other tool types)
// ---------------------------------------------------------------------------

const GenericExpanded = ({ data, outputPreview }) => (
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

// ---------------------------------------------------------------------------
// ToolExpanded — dispatch to type-specific or generic expanded view
// ---------------------------------------------------------------------------

const ToolExpanded = ({ sessionId, rowId, http, outputPreview, diffPreview, toolType }) => {
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

  const data = content || {}

  if (toolType === 'guardianAssessment') {
    return <GuardianExpanded data={data} />
  }

  return <GenericExpanded data={data} outputPreview={outputPreview} />
}

export { ToolExpanded }
