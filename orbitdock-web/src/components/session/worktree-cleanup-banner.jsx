import { useState } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import styles from './worktree-cleanup-banner.module.css'

const WorktreeCleanupBanner = ({ worktreeId, onDelete }) => {
  const [deleting, setDeleting] = useState(false)
  const [deleted, setDeleted] = useState(false)

  if (deleted) return null

  const handleDelete = async () => {
    if (deleting) return
    setDeleting(true)
    try {
      await onDelete(worktreeId)
      setDeleted(true)
    } finally {
      setDeleting(false)
    }
  }

  return (
    <div class={styles.banner} role="status" aria-live="polite">
      <span class={styles.icon} aria-hidden="true">
        <svg
          width="14"
          height="14"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <line x1="6" y1="3" x2="6" y2="15" />
          <circle cx="18" cy="6" r="3" />
          <circle cx="6" cy="18" r="3" />
          <path d="M18 9a9 9 0 0 1-9 9" />
        </svg>
      </span>
      <span class={styles.label}>This session used a worktree.</span>
      <span class={styles.hint}>Clean up?</span>
      <Button
        variant="ghost"
        size="sm"
        class={styles.deleteBtn}
        onClick={handleDelete}
        loading={deleting}
        disabled={deleting}
      >
        Delete Worktree
      </Button>
    </div>
  )
}

export { WorktreeCleanupBanner }
