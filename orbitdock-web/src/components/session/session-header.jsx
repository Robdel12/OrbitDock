import { useState, useRef, useEffect } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { StatusDot } from '../ui/status-dot.jsx'
import { Badge } from '../ui/badge.jsx'
import { Button } from '../ui/button.jsx'
import { ActionPopover } from './action-popover.jsx'
import { viewMode, toggleViewMode } from '../../stores/view-mode.js'
import popoverStyles from './action-popover.module.css'
import styles from './session-header.module.css'

// ---------------------------------------------------------------------------
// Inline rename input
// ---------------------------------------------------------------------------

const RenameInput = ({ value, onSave, onCancel }) => {
  const [draft, setDraft] = useState(value)
  const inputRef = useRef(null)

  useEffect(() => {
    inputRef.current?.select()
  }, [])

  const commit = () => {
    const trimmed = draft.trim()
    if (trimmed && trimmed !== value) {
      onSave(trimmed)
    } else {
      onCancel()
    }
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter') {
      e.preventDefault()
      commit()
    } else if (e.key === 'Escape') {
      e.preventDefault()
      onCancel()
    }
  }

  return (
    <input
      ref={inputRef}
      class={styles.renameInput}
      value={draft}
      onInput={(e) => setDraft(e.target.value)}
      onKeyDown={handleKeyDown}
      onBlur={commit}
    />
  )
}

// ---------------------------------------------------------------------------
// Fork popover body
// ---------------------------------------------------------------------------

const ForkPopover = ({ open, onClose, onFork }) => {
  const [nthMessage, setNthMessage] = useState('')

  const handleSubmit = (e) => {
    e.preventDefault()
    const val = nthMessage.trim()
    onFork(val ? parseInt(val, 10) : undefined)
    onClose()
  }

  return (
    <ActionPopover open={open} onClose={onClose} title="Fork session">
      <form onSubmit={handleSubmit}>
        <div class={popoverStyles.field}>
          <label class={popoverStyles.label}>Fork at message # (optional)</label>
          <input
            class={popoverStyles.input}
            type="number"
            min="1"
            placeholder="Last message"
            value={nthMessage}
            onInput={(e) => setNthMessage(e.target.value)}
            autoFocus
          />
        </div>
        <div class={popoverStyles.actions}>
          <Button variant="ghost" size="sm" type="button" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="primary" size="sm" type="submit">
            Fork
          </Button>
        </div>
      </form>
    </ActionPopover>
  )
}

// ---------------------------------------------------------------------------
// Rollback popover body
// ---------------------------------------------------------------------------

const RollbackPopover = ({ open, onClose, onRollback }) => {
  const [numTurns, setNumTurns] = useState('1')

  const handleSubmit = (e) => {
    e.preventDefault()
    const val = parseInt(numTurns, 10)
    if (!val || val < 1) return
    onRollback(val)
    onClose()
  }

  return (
    <ActionPopover open={open} onClose={onClose} title="Roll back turns">
      <form onSubmit={handleSubmit}>
        <div class={popoverStyles.field}>
          <label class={popoverStyles.label}>Number of turns</label>
          <input
            class={popoverStyles.input}
            type="number"
            min="1"
            value={numTurns}
            onInput={(e) => setNumTurns(e.target.value)}
            autoFocus
          />
        </div>
        <div class={popoverStyles.actions}>
          <Button variant="ghost" size="sm" type="button" onClick={onClose}>
            Cancel
          </Button>
          <Button variant="danger" size="sm" type="submit">
            Rollback
          </Button>
        </div>
      </form>
    </ActionPopover>
  )
}

// ---------------------------------------------------------------------------
// Overflow dropdown — session management actions
// ---------------------------------------------------------------------------

const OverflowMenu = ({ open, onClose, children }) => {
  const ref = useRef(null)

  useEffect(() => {
    if (!open) return

    const handleKey = (e) => {
      if (e.key === 'Escape') onClose()
    }
    const handleClick = (e) => {
      if (ref.current && !ref.current.contains(e.target)) onClose()
    }

    document.addEventListener('keydown', handleKey)
    document.addEventListener('mousedown', handleClick)
    return () => {
      document.removeEventListener('keydown', handleKey)
      document.removeEventListener('mousedown', handleClick)
    }
  }, [open, onClose])

  if (!open) return null

  return (
    <div class={styles.overflowMenu} ref={ref}>
      {children}
    </div>
  )
}

// ---------------------------------------------------------------------------
// View mode toggle icon (inline SVG)
// ---------------------------------------------------------------------------

const ViewModeIcon = ({ mode }) => {
  if (mode === 'focused') {
    return (
      <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
        <rect x="2" y="3" width="12" height="3" rx="1" />
        <rect x="2" y="8" width="12" height="5" rx="1" />
      </svg>
    )
  }
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
      <line x1="2" y1="3" x2="14" y2="3" />
      <line x1="2" y1="6" x2="14" y2="6" />
      <line x1="2" y1="9" x2="14" y2="9" />
      <line x1="2" y1="12" x2="10" y2="12" />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Status label text
// ---------------------------------------------------------------------------

const STATUS_TEXT = {
  working: 'Working',
  waiting: 'Waiting',
  permission: 'Approval',
  question: 'Question',
  reply: 'Waiting',
  ended: 'Ended',
}

// ---------------------------------------------------------------------------
// Main SessionHeader — matches native app: back, dot, name, status, controls
// ---------------------------------------------------------------------------

const SessionHeader = ({
  session,
  onCompact,
  onUndo,
  onEnd,
  onRename,
  onFork,
  onTakeover,
  onRollback,
  onToggleCapabilities,
  capabilitiesOpen,
  reviewOpen = false,
  onReviewToggle,
}) => {
  const [, navigate] = useLocation()
  const [renaming, setRenaming] = useState(false)
  const [subPopover, setSubPopover] = useState('none')
  const [overflowOpen, setOverflowOpen] = useState(false)

  if (!session) return null

  const displayName = session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`
  const isActive = session.status === 'active'
  const isPassive = session.work_status === 'reply' || session.work_status === 'ended'
  const showTakeover = isActive && isPassive
  const statusText = STATUS_TEXT[session.work_status] || session.work_status

  const handleRenameSave = (name) => {
    setRenaming(false)
    onRename?.(name)
  }

  const handleFork = (nthUserMessage) => {
    onFork?.(nthUserMessage)
  }

  const handleRollback = (numTurns) => {
    onRollback?.(numTurns)
  }

  const openFork = () => { setSubPopover('fork'); setOverflowOpen(false) }
  const openRollback = () => { setSubPopover('rollback'); setOverflowOpen(false) }
  const closeSubPopover = () => setSubPopover('none')

  return (
    <header class={styles.header}>
      {/* Left: Back + identity */}
      <div class={styles.leading}>
        <button
          class={styles.backBtn}
          onClick={() => navigate('/')}
          aria-label="Back to dashboard"
        >
          <svg width="7" height="12" viewBox="0 0 7 12" fill="none">
            <path d="M6 1L1 6l5 5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
          </svg>
          <span class={styles.backLabel}>Dashboard</span>
        </button>

        <StatusDot status={session.work_status} />

        {renaming ? (
          <RenameInput
            value={displayName}
            onSave={handleRenameSave}
            onCancel={() => setRenaming(false)}
          />
        ) : (
          <button
            class={styles.name}
            title="Click to rename"
            onClick={() => setRenaming(true)}
            type="button"
          >
            {displayName}
          </button>
        )}

        <span class={`${styles.statusLabel} ${styles[`status-${session.work_status}`] || ''}`}>
          {statusText}
        </span>

        <button
          class={`${styles.iconBtn} ${viewMode.value === 'focused' ? styles.iconBtnActive : ''}`}
          onClick={toggleViewMode}
          aria-label={viewMode.value === 'focused' ? 'Switch to verbose view' : 'Switch to focused view'}
          title={viewMode.value === 'focused' ? 'Focused' : 'Verbose'}
        >
          <ViewModeIcon mode={viewMode.value} />
        </button>
      </div>

      {/* Right: Action pill buttons */}
      <div class={styles.actions}>
        <button
          class={`${styles.pillBtn} ${capabilitiesOpen ? styles.pillBtnActive : ''}`}
          onClick={onToggleCapabilities}
        >
          Tools
        </button>

        {onReviewToggle && (
          <button
            class={`${styles.pillBtn} ${reviewOpen ? styles.pillBtnActive : ''}`}
            onClick={onReviewToggle}
          >
            Review
          </button>
        )}

        {isActive && (
          <>
            <button class={styles.pillBtn} onClick={onUndo}>Undo</button>
            <button class={styles.pillBtn} onClick={openFork}>Fork</button>
            <button class={styles.pillBtn} onClick={openRollback}>Rollback</button>
            <button class={styles.pillBtn} onClick={onCompact}>Compact</button>
            <button class={`${styles.pillBtn} ${styles.pillBtnDanger}`} onClick={onEnd}>End</button>

            {showTakeover && (
              <button class={styles.pillBtn} onClick={onTakeover}>Take Over</button>
            )}
          </>
        )}

        {/* Overflow trigger for narrow viewports */}
        {isActive && (
          <div class={styles.popoverAnchor}>
            <button
              class={`${styles.iconBtn} ${styles.overflowTrigger}`}
              onClick={() => setOverflowOpen((v) => !v)}
              aria-label="More actions"
              aria-expanded={overflowOpen}
            >
              <svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor">
                <circle cx="3" cy="8" r="1.5" />
                <circle cx="8" cy="8" r="1.5" />
                <circle cx="13" cy="8" r="1.5" />
              </svg>
            </button>
            <OverflowMenu open={overflowOpen} onClose={() => setOverflowOpen(false)}>
              {showTakeover && (
                <button class={styles.overflowItem} onClick={() => { onTakeover?.(); setOverflowOpen(false) }}>
                  Take Over
                </button>
              )}
              <button class={styles.overflowItem} onClick={() => { onUndo?.(); setOverflowOpen(false) }}>
                Undo
              </button>
              <button class={styles.overflowItem} onClick={openFork}>
                Fork…
              </button>
              <button class={styles.overflowItem} onClick={openRollback}>
                Rollback…
              </button>
              <button class={styles.overflowItem} onClick={() => { onCompact?.(); setOverflowOpen(false) }}>
                Compact
              </button>
              <button
                class={`${styles.overflowItem} ${styles.overflowItemDanger}`}
                onClick={() => { onEnd?.(); setOverflowOpen(false) }}
              >
                End
              </button>
            </OverflowMenu>
          </div>
        )}
      </div>

      {/* Popovers rendered outside flow */}
      <div class={styles.popoverAnchor}>
        <ForkPopover open={subPopover === 'fork'} onClose={closeSubPopover} onFork={handleFork} />
      </div>
      <div class={styles.popoverAnchor}>
        <RollbackPopover open={subPopover === 'rollback'} onClose={closeSubPopover} onRollback={handleRollback} />
      </div>
    </header>
  )
}

export { SessionHeader }
