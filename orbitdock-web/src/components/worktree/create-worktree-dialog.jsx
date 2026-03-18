import { useState } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import styles from './create-worktree-dialog.module.css'

const CreateWorktreeDialog = ({ open, onClose, onCreate }) => {
  const [repoPath, setRepoPath] = useState('')
  const [branchName, setBranchName] = useState('')
  const [baseBranch, setBaseBranch] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState(null)

  const handleSubmit = async (e) => {
    e.preventDefault()
    if (!repoPath.trim() || !branchName.trim()) return
    setSubmitting(true)
    setError(null)
    try {
      const body = {
        repo_path: repoPath.trim(),
        branch_name: branchName.trim(),
      }
      if (baseBranch.trim()) body.base_branch = baseBranch.trim()
      await onCreate(body)
      setRepoPath('')
      setBranchName('')
      setBaseBranch('')
      onClose()
    } catch (err) {
      setError(err.message || 'Failed to create worktree')
    } finally {
      setSubmitting(false)
    }
  }

  const handleClose = () => {
    if (submitting) return
    setError(null)
    onClose()
  }

  if (!open) return null

  return (
    <div class={styles.backdrop} onClick={handleClose}>
      <div class={styles.dialog} onClick={(e) => e.stopPropagation()}>
        <div class={styles.accent} />
        <form class={styles.content} onSubmit={handleSubmit}>
          <h2 class={styles.title}>New Worktree</h2>

          <div class={styles.field}>
            <label class={styles.label}>Repository Path</label>
            <input
              class={styles.input}
              type="text"
              placeholder="/path/to/repo"
              value={repoPath}
              onInput={(e) => setRepoPath(e.target.value)}
              autoFocus
              disabled={submitting}
            />
          </div>

          <div class={styles.field}>
            <label class={styles.label}>Branch Name</label>
            <input
              class={styles.input}
              type="text"
              placeholder="feature/my-branch"
              value={branchName}
              onInput={(e) => setBranchName(e.target.value)}
              disabled={submitting}
            />
          </div>

          <div class={styles.field}>
            <label class={styles.label}>
              Base Branch
              <span class={styles.optional}> — optional</span>
            </label>
            <input
              class={styles.input}
              type="text"
              placeholder="main"
              value={baseBranch}
              onInput={(e) => setBaseBranch(e.target.value)}
              disabled={submitting}
            />
          </div>

          {error && <p class={styles.error}>{error}</p>}

          <div class={styles.actions}>
            <Button variant="ghost" size="md" type="button" onClick={handleClose} disabled={submitting}>
              Cancel
            </Button>
            <Button
              variant="primary"
              size="md"
              type="submit"
              loading={submitting}
              disabled={!repoPath.trim() || !branchName.trim()}
            >
              Create
            </Button>
          </div>
        </form>
      </div>
    </div>
  )
}

export { CreateWorktreeDialog }
