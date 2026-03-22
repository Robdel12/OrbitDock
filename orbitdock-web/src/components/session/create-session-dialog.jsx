import { useEffect, useState } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import styles from './create-session-dialog.module.css'

const CreateSessionDialog = ({ open, onClose, onCreate, http }) => {
  const [provider, setProvider] = useState('claude')
  const [cwd, setCwd] = useState('')
  const [model, setModel] = useState('')
  const [models, setModels] = useState([])
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    if (!open) return
    setError(null)
    const fetchModels = async () => {
      try {
        const data = await http.get(`/api/models/${provider}`)
        setModels(data.models || [])
        setModel('')
      } catch (_err) {
        setModels([])
      }
    }
    fetchModels()
  }, [provider, open])

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!cwd.trim()) return
    setSubmitting(true)
    setError(null)
    try {
      const body = { provider, cwd: cwd.trim() }
      if (model) body.model = model
      await onCreate(body)
      onClose()
    } catch (err) {
      setError(err.message || 'Failed to create session')
    } finally {
      setSubmitting(false)
    }
  }

  if (!open) return null

  return (
    <div class={styles.backdrop} onClick={onClose}>
      <div class={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <div class={styles.accent} />
        <form class={styles.content} onSubmit={handleSubmit}>
          <h2 class={styles.title}>New Session</h2>

          <div class={styles.field}>
            <label class={styles.label}>Provider</label>
            <div class={styles.providerToggle}>
              <button
                type="button"
                class={`${styles.providerBtn} ${provider === 'claude' ? styles.providerActive : ''}`}
                style={provider === 'claude' ? { '--btn-color': 'var(--color-provider-claude)' } : undefined}
                onClick={() => setProvider('claude')}
              >
                Claude
              </button>
              <button
                type="button"
                class={`${styles.providerBtn} ${provider === 'codex' ? styles.providerActive : ''}`}
                style={provider === 'codex' ? { '--btn-color': 'var(--color-provider-codex)' } : undefined}
                onClick={() => setProvider('codex')}
              >
                Codex
              </button>
            </div>
          </div>

          <div class={styles.field}>
            <label class={styles.label}>Working Directory</label>
            <input
              class={styles.input}
              type="text"
              placeholder="/path/to/project"
              value={cwd}
              onInput={(e) => setCwd(e.target.value)}
              autoFocus
            />
          </div>

          <div class={styles.field}>
            <label class={styles.label}>Model</label>
            <select class={styles.select} value={model} onChange={(e) => setModel(e.target.value)}>
              <option value="">Default</option>
              {models.map((m) => (
                <option key={m.value || m.id || m.model} value={m.value || m.id || m.model}>
                  {m.display_name || m.model || m.value}
                </option>
              ))}
            </select>
          </div>

          {error && <p class={styles.error}>{error}</p>}

          <div class={styles.actions}>
            <Button variant="ghost" size="md" type="button" onClick={onClose}>
              Cancel
            </Button>
            <Button variant="primary" size="md" type="submit" loading={submitting} disabled={!cwd.trim()}>
              Create
            </Button>
          </div>
        </form>
      </div>
    </div>
  )
}

export { CreateSessionDialog }
