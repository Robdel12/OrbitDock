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
      <span class={styles.icon} aria-hidden="true">⑂</span>
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
