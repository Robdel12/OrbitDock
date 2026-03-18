import { useState, useRef, useEffect } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import styles from './comment-input.module.css'

/**
 * Minimal inline comment composer.
 *
 * Props:
 *   onSubmit(body: string) — called with trimmed body when submitted
 *   onCancel()             — called when user cancels
 *   loading                — shows spinner on Submit button
 *   autoFocus              — default true
 */
const CommentInput = ({ onSubmit, onCancel, loading = false, autoFocus = true }) => {
  const [body, setBody] = useState('')
  const textareaRef = useRef(null)

  useEffect(() => {
    if (autoFocus) textareaRef.current?.focus()
  }, [autoFocus])

  const handleSubmit = (e) => {
    e?.preventDefault()
    const trimmed = body.trim()
    if (!trimmed || loading) return
    onSubmit(trimmed)
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      handleSubmit()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      onCancel?.()
    }
  }

  return (
    <form class={styles.form} onSubmit={handleSubmit}>
      <textarea
        ref={textareaRef}
        class={styles.textarea}
        value={body}
        onInput={(e) => setBody(e.target.value)}
        onKeyDown={handleKeyDown}
        placeholder="Leave a comment… (Cmd+Enter to submit)"
        rows={3}
      />
      <div class={styles.actions}>
        <Button
          variant="ghost"
          size="sm"
          type="button"
          onClick={onCancel}
          disabled={loading}
        >
          Cancel
        </Button>
        <Button
          variant="primary"
          size="sm"
          type="submit"
          disabled={!body.trim()}
          loading={loading}
        >
          Comment
        </Button>
      </div>
    </form>
  )
}

export { CommentInput }
