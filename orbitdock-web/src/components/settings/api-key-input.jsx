import { useState } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import { Badge } from '../ui/badge.jsx'
import styles from './api-key-input.module.css'

const ApiKeyInput = ({ label, currentValue, onSave, validate, placeholder }) => {
  const [editing, setEditing] = useState(false)
  const [inputValue, setInputValue] = useState('')
  const [saving, setSaving] = useState(false)
  const [feedback, setFeedback] = useState(null) // { type: 'success' | 'error', message: string }

  const isConfigured = currentValue?.configured === true
  const maskedDisplay = isConfigured && currentValue?.masked ? currentValue.masked : null

  const handleEdit = () => {
    setInputValue('')
    setFeedback(null)
    setEditing(true)
  }

  const handleCancel = () => {
    setEditing(false)
    setInputValue('')
    setFeedback(null)
  }

  const handleSave = async () => {
    const trimmed = inputValue.trim()

    if (validate) {
      const validationError = validate(trimmed)
      if (validationError) {
        setFeedback({ type: 'error', message: validationError })
        return
      }
    }

    setSaving(true)
    setFeedback(null)

    try {
      await onSave(trimmed)
      setEditing(false)
      setInputValue('')
      setFeedback({ type: 'success', message: 'Saved' })
    } catch (err) {
      setFeedback({ type: 'error', message: err.message || 'Save failed' })
    } finally {
      setSaving(false)
    }
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter') handleSave()
    if (e.key === 'Escape') handleCancel()
  }

  return (
    <div class={styles.root}>
      <div class={styles.header}>
        <span class={styles.label}>{label}</span>
        <div class={styles.statusRow}>
          {!editing && (
            <Badge
              variant={isConfigured ? 'status' : 'meta'}
              color={isConfigured ? 'feedback-positive' : 'feedback-negative'}
            >
              {isConfigured ? 'Configured' : 'Not Set'}
            </Badge>
          )}
          {!editing && (
            <Button variant="ghost" size="sm" onClick={handleEdit}>
              {isConfigured ? 'Update' : 'Set Key'}
            </Button>
          )}
        </div>
      </div>

      {!editing && isConfigured && maskedDisplay && (
        <div class={styles.maskedKey}>{maskedDisplay}</div>
      )}

      {editing && (
        <div class={styles.editRow}>
          <input
            class={styles.input}
            type="password"
            placeholder={placeholder}
            value={inputValue}
            onInput={(e) => setInputValue(e.target.value)}
            onKeyDown={handleKeyDown}
            autoFocus
            autocomplete="off"
            spellcheck={false}
          />
          <div class={styles.editActions}>
            <Button variant="ghost" size="sm" onClick={handleCancel} disabled={saving}>
              Cancel
            </Button>
            <Button
              variant="primary"
              size="sm"
              onClick={handleSave}
              loading={saving}
              disabled={!inputValue.trim()}
            >
              Save
            </Button>
          </div>
        </div>
      )}

      {feedback && (
        <div class={`${styles.feedback} ${styles[feedback.type]}`}>
          {feedback.message}
        </div>
      )}
    </div>
  )
}

export { ApiKeyInput }
