import { useState } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import { addComment, removeComment, updateComment } from '../../stores/review.js'
import { CommentInput } from './comment-input.jsx'
import styles from './comment-thread.module.css'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const formatRelativeTime = (isoString) => {
  if (!isoString) return ''
  const date = new Date(isoString)
  const diff = Date.now() - date.getTime()
  const minutes = Math.floor(diff / 60000)
  if (minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  const days = Math.floor(hours / 24)
  return `${days}d ago`
}

// ---------------------------------------------------------------------------
// Single comment bubble
// ---------------------------------------------------------------------------

const CommentBubble = ({ comment, onEdit, onDelete }) => {
  const [confirmingDelete, setConfirmingDelete] = useState(false)

  return (
    <div class={styles.bubble}>
      <div class={styles.bubbleMeta}>
        <span class={styles.author}>{comment.author || 'You'}</span>
        <span class={styles.timestamp}>{formatRelativeTime(comment.created_at)}</span>
        <div class={styles.bubbleActions}>
          <button class={styles.actionBtn} onClick={onEdit} title="Edit comment">
            Edit
          </button>
          {confirmingDelete ? (
            <>
              <button
                class={`${styles.actionBtn} ${styles.actionBtnDanger}`}
                onClick={() => {
                  setConfirmingDelete(false)
                  onDelete()
                }}
              >
                Confirm
              </button>
              <button class={styles.actionBtn} onClick={() => setConfirmingDelete(false)}>
                No
              </button>
            </>
          ) : (
            <button
              class={`${styles.actionBtn} ${styles.actionBtnDanger}`}
              onClick={() => setConfirmingDelete(true)}
              title="Delete comment"
            >
              Delete
            </button>
          )}
        </div>
      </div>
      <p class={styles.body}>{comment.body}</p>
    </div>
  )
}

// ---------------------------------------------------------------------------
// EditableComment — CommentBubble with an inline edit mode
// ---------------------------------------------------------------------------

const EditableComment = ({ comment }) => {
  const [editing, setEditing] = useState(false)
  const [loading, setLoading] = useState(false)

  const handleSave = (body) => {
    setLoading(true)
    http
      .patch(`/api/review-comments/${comment.id}`, { body })
      .then((data) => {
        updateComment(data?.comment || { ...comment, body })
        setEditing(false)
      })
      .catch((err) => console.warn('[review] update comment failed:', err.message))
      .finally(() => setLoading(false))
  }

  const handleDelete = () => {
    http
      .del(`/api/review-comments/${comment.id}`)
      .then(() => removeComment(comment.id))
      .catch((err) => console.warn('[review] delete comment failed:', err.message))
  }

  if (editing) {
    return <CommentInput onSubmit={handleSave} onCancel={() => setEditing(false)} loading={loading} />
  }

  return <CommentBubble comment={comment} onEdit={() => setEditing(true)} onDelete={handleDelete} />
}

// ---------------------------------------------------------------------------
// CommentThread
// ---------------------------------------------------------------------------

/**
 * Full thread at a diff line: existing comments + new comment input.
 *
 * Props:
 *   comments    — comment[] for this line
 *   sessionId   — used when creating new comments
 *   filePath    — file path being commented on
 *   lineNumber  — line number (new_line from diff)
 *   onClose()   — called when user cancels with no existing comments
 */
const CommentThread = ({ comments = [], sessionId, filePath, lineNumber, onClose }) => {
  const [showInput, setShowInput] = useState(comments.length === 0)
  const [loading, setLoading] = useState(false)

  const handleSubmit = (body) => {
    setLoading(true)
    http
      .post(`/api/sessions/${sessionId}/review-comments`, {
        body,
        file_path: filePath,
        line_number: lineNumber,
      })
      .then((data) => {
        if (data?.comment) addComment(data.comment)
        setShowInput(false)
      })
      .catch((err) => console.warn('[review] create comment failed:', err.message))
      .finally(() => setLoading(false))
  }

  const handleCancel = () => {
    if (comments.length === 0) {
      onClose?.()
    } else {
      setShowInput(false)
    }
  }

  return (
    <div class={styles.thread}>
      {comments.map((c) => (
        <EditableComment key={c.id} comment={c} />
      ))}
      {!showInput && comments.length > 0 && (
        <button class={styles.addReplyBtn} onClick={() => setShowInput(true)}>
          + Reply
        </button>
      )}
      {showInput && <CommentInput onSubmit={handleSubmit} onCancel={handleCancel} loading={loading} autoFocus />}
    </div>
  )
}

export { CommentThread }
