import { useEffect, useState } from 'preact/hooks'
import { Badge } from '../components/ui/badge.jsx'
import { Button } from '../components/ui/button.jsx'
import { Card } from '../components/ui/card.jsx'
import { Spinner } from '../components/ui/spinner.jsx'
import { CreateWorktreeDialog } from '../components/worktree/create-worktree-dialog.jsx'
import { http } from '../stores/connection.js'
import styles from './worktrees.module.css'

const HEALTH_COLORS = {
  healthy: 'feedback-positive',
  degraded: 'feedback-caution',
  missing: 'feedback-negative',
  unknown: 'status-ended',
}

const WorktreeItem = ({ worktree, onDelete }) => {
  const [confirming, setConfirming] = useState(false)
  const [deleting, setDeleting] = useState(false)

  const handleDeleteClick = () => {
    setConfirming(true)
  }

  const handleConfirm = async () => {
    setDeleting(true)
    try {
      await onDelete(worktree.id)
    } finally {
      setDeleting(false)
      setConfirming(false)
    }
  }

  const handleCancel = () => {
    setConfirming(false)
  }

  const healthColor = HEALTH_COLORS[worktree.health] || HEALTH_COLORS.unknown

  return (
    <div class={styles.worktreeItem}>
      <Card>
        <div class={styles.worktreeRow}>
          <div class={styles.worktreeMain}>
            <span class={styles.branchName}>{worktree.branch_name || worktree.branch || '(detached)'}</span>
            <span class={styles.worktreePath}>{worktree.path}</span>
          </div>
          <div class={styles.worktreeMeta}>
            {worktree.health && (
              <Badge variant="status" color={healthColor}>
                {worktree.health}
              </Badge>
            )}
            {confirming ? (
              <div class={styles.confirmRow}>
                <span class={styles.confirmText}>Delete?</span>
                <Button variant="danger" size="sm" onClick={handleConfirm} loading={deleting} disabled={deleting}>
                  Yes
                </Button>
                <Button variant="ghost" size="sm" onClick={handleCancel} disabled={deleting}>
                  No
                </Button>
              </div>
            ) : (
              <Button variant="ghost" size="sm" onClick={handleDeleteClick}>
                Delete
              </Button>
            )}
          </div>
        </div>
      </Card>
    </div>
  )
}

const RepoGroup = ({ repoPath, worktrees, onDelete }) => (
  <div class={styles.repoGroup}>
    <div class={styles.groupHeader}>
      <span class={styles.repoPath}>{repoPath}</span>
      <Badge variant="meta">{worktrees.length}</Badge>
    </div>
    <div class={styles.groupList}>
      {worktrees.map((wt) => (
        <WorktreeItem key={wt.id} worktree={wt} onDelete={onDelete} />
      ))}
    </div>
  </div>
)

const groupByRepo = (worktrees) => {
  const map = new Map()
  for (const wt of worktrees) {
    const key = wt.repo_path || wt.repository_root || 'Unknown'
    if (!map.has(key)) map.set(key, [])
    map.get(key).push(wt)
  }
  return [...map.entries()].map(([path, items]) => ({ path, items }))
}

const WorktreesPage = () => {
  const [worktrees, setWorktrees] = useState([])
  const [loading, setLoading] = useState(true)
  const [dialogOpen, setDialogOpen] = useState(false)
  const [discoverPath, setDiscoverPath] = useState('')
  const [discovering, setDiscovering] = useState(false)
  const [discoverError, setDiscoverError] = useState(null)
  const [showDiscover, setShowDiscover] = useState(false)

  const load = async () => {
    try {
      const data = await http.get('/api/worktrees')
      setWorktrees(data.worktrees || [])
    } catch (err) {
      console.warn('[worktrees] failed to load:', err.message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    load()
  }, [])

  const handleCreate = async (body) => {
    await http.post('/api/worktrees', body)
    await load()
  }

  const handleDelete = async (id) => {
    await http.del(`/api/worktrees/${id}`)
    setWorktrees((prev) => prev.filter((wt) => wt.id !== id))
  }

  const handleDiscover = async (e) => {
    e.preventDefault()
    if (!discoverPath.trim()) return
    setDiscovering(true)
    setDiscoverError(null)
    try {
      await http.post('/api/worktrees/discover', { repo_path: discoverPath.trim() })
      setDiscoverPath('')
      setShowDiscover(false)
      await load()
    } catch (err) {
      setDiscoverError(err.message || 'Discovery failed')
    } finally {
      setDiscovering(false)
    }
  }

  const groups = groupByRepo(worktrees)

  if (loading) {
    return (
      <div class={styles.page}>
        <div class={styles.loadingState}>
          <Spinner size="lg" />
        </div>
      </div>
    )
  }

  return (
    <div class={styles.page}>
      <div class={styles.pageHeader}>
        <h1 class={styles.title}>Worktrees</h1>
        <div class={styles.headerActions}>
          <Button variant="secondary" size="sm" onClick={() => setShowDiscover((v) => !v)}>
            Discover
          </Button>
          <Button variant="primary" size="sm" onClick={() => setDialogOpen(true)}>
            Create Worktree
          </Button>
        </div>
      </div>

      {showDiscover && (
        <form class={styles.discoverForm} onSubmit={handleDiscover}>
          <input
            class={styles.discoverInput}
            type="text"
            placeholder="/path/to/repo"
            value={discoverPath}
            onInput={(e) => setDiscoverPath(e.target.value)}
            autoFocus
            disabled={discovering}
          />
          <Button variant="primary" size="sm" type="submit" loading={discovering} disabled={!discoverPath.trim()}>
            Discover
          </Button>
          <Button
            variant="ghost"
            size="sm"
            type="button"
            onClick={() => {
              setShowDiscover(false)
              setDiscoverError(null)
            }}
            disabled={discovering}
          >
            Cancel
          </Button>
          {discoverError && <span class={styles.discoverError}>{discoverError}</span>}
        </form>
      )}

      {worktrees.length === 0 ? (
        <div class={styles.emptyState}>
          <p class={styles.emptyText}>No worktrees found.</p>
          <p class={styles.emptyHint}>Create a new worktree or discover existing ones by repo path.</p>
        </div>
      ) : (
        <div class={styles.content}>
          {groups.map((group) => (
            <RepoGroup key={group.path} repoPath={group.path} worktrees={group.items} onDelete={handleDelete} />
          ))}
        </div>
      )}

      <CreateWorktreeDialog open={dialogOpen} onClose={() => setDialogOpen(false)} onCreate={handleCreate} />
    </div>
  )
}

export { WorktreesPage }
