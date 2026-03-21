import { useState, useRef, useEffect } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { StatusDot } from '../ui/status-dot.jsx'
import { ActionPopover } from './action-popover.jsx'
import { viewMode, toggleViewMode } from '../../stores/view-mode.js'
import popoverStyles from './action-popover.module.css'
import { Button } from '../ui/button.jsx'
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
// Overflow dropdown (mobile)
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
// SVG Icons
// ---------------------------------------------------------------------------

const ConversationIcon = () => (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <path d="M2 3.5A1.5 1.5 0 013.5 2h9A1.5 1.5 0 0114 3.5v7a1.5 1.5 0 01-1.5 1.5H6l-3 2.5V12H3.5A1.5 1.5 0 012 10.5v-7z" />
  </svg>
)

const ReviewIcon = () => (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2" y="2" width="12" height="12" rx="1.5" />
    <path d="M5 6h6M5 8.5h4" />
    <circle cx="11" cy="11" r="2.5" fill="var(--color-bg-secondary)" />
    <circle cx="11" cy="11" r="2" />
  </svg>
)

const SplitIcon = () => (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <rect x="1.5" y="2.5" width="13" height="11" rx="1.5" />
    <line x1="8" y1="2.5" x2="8" y2="13.5" />
  </svg>
)

const FocusedViewIcon = () => (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <rect x="2" y="3" width="12" height="3" rx="1" />
    <rect x="2" y="8" width="12" height="5" rx="1" />
  </svg>
)

const VerboseViewIcon = () => (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round">
    <line x1="2" y1="3" x2="14" y2="3" />
    <line x1="2" y1="6" x2="14" y2="6" />
    <line x1="2" y1="9" x2="14" y2="9" />
    <line x1="2" y1="12" x2="10" y2="12" />
  </svg>
)

const SearchIcon = () => (
  <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="7" cy="7" r="4.5" />
    <path d="M10.5 10.5L14 14" />
  </svg>
)

// ---------------------------------------------------------------------------
// Model badge — compact pill showing model short name
// ---------------------------------------------------------------------------

const MODEL_LABELS = {
  'claude-opus-4-6': 'Opus',
  'claude-sonnet-4-6': 'Sonnet',
  'claude-haiku-4-5-20251001': 'Haiku',
  'claude-3-5-sonnet-20241022': 'Sonnet 3.5',
  'claude-3-5-haiku-20241022': 'Haiku 3.5',
}

const MODEL_COLORS = {
  opus: '--color-status-permission',
  sonnet: '--color-accent',
  haiku: '--color-feedback-caution',
}

const getModelLabel = (model) => {
  if (!model) return null
  if (MODEL_LABELS[model]) return MODEL_LABELS[model]
  // Extract short name: "opus", "sonnet", "haiku", or last segment
  const lower = model.toLowerCase()
  if (lower.includes('opus')) return 'Opus'
  if (lower.includes('sonnet')) return 'Sonnet'
  if (lower.includes('haiku')) return 'Haiku'
  if (lower.includes('gpt-4')) return 'GPT-4'
  if (lower.includes('gpt-3')) return 'GPT-3.5'
  if (lower.includes('o1')) return 'o1'
  if (lower.includes('o3')) return 'o3'
  // Fallback: last dash-segment
  const parts = model.split('-')
  return parts[parts.length - 1]
}

const getModelColorVar = (model) => {
  if (!model) return null
  const lower = model.toLowerCase()
  if (lower.includes('opus')) return MODEL_COLORS.opus
  if (lower.includes('sonnet')) return MODEL_COLORS.sonnet
  if (lower.includes('haiku')) return MODEL_COLORS.haiku
  return null
}

const ModelBadge = ({ model }) => {
  const label = getModelLabel(model)
  if (!label) return null

  const colorVar = getModelColorVar(model)
  const style = colorVar
    ? { '--model-color': `var(${colorVar})` }
    : undefined

  return (
    <span
      class={`${styles.modelBadge} ${colorVar ? styles.modelBadgeColored : ''}`}
      title={model}
    >
      {label}
    </span>
  )
}

// ---------------------------------------------------------------------------
// Effort badge
// ---------------------------------------------------------------------------

const EFFORT_LABELS = { low: 'Low', medium: 'Med', high: 'High', max: 'Max' }
const EFFORT_COLORS = {
  low: '--color-feedback-positive',
  medium: '--color-feedback-caution',
  high: '--color-feedback-warning',
  max: '--color-feedback-negative',
}

const EffortBadge = ({ effort }) => {
  if (!effort || effort === 'medium') return null
  const label = EFFORT_LABELS[effort] || effort
  const colorVar = EFFORT_COLORS[effort]
  const style = colorVar
    ? { '--effort-color': `var(${colorVar})` }
    : undefined

  return (
    <span class={styles.effortBadge} style={style}>
      {label}
    </span>
  )
}

// ---------------------------------------------------------------------------
// Context pill — inline token usage gauge
// ---------------------------------------------------------------------------

const ContextPill = ({ tokenUsage }) => {
  if (!tokenUsage) return null
  const total = (tokenUsage.input_tokens || 0) + (tokenUsage.output_tokens || 0)
  if (total === 0) return null

  const contextWindow = tokenUsage.context_window_total
  const pct = contextWindow ? Math.round((total / contextWindow) * 100) : null
  if (pct == null) return null

  const colorClass = pct >= 90
    ? styles.contextDanger
    : pct >= 70
      ? styles.contextWarning
      : ''

  return (
    <span class={`${styles.intelligencePill} ${colorClass}`} title={`Context: ${pct}% used (${total.toLocaleString()} tokens)`}>
      <svg width="10" height="10" viewBox="0 0 20 20" fill="none">
        <circle cx="10" cy="10" r="8" stroke="currentColor" stroke-width="2" opacity="0.2" />
        <circle
          cx="10" cy="10" r="8"
          stroke="currentColor" stroke-width="2"
          stroke-dasharray={`${(pct / 100) * 50.27} 50.27`}
          stroke-linecap="round"
          transform="rotate(-90 10 10)"
        />
      </svg>
      <span>{pct}%</span>
    </span>
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
// Layout mode values
// ---------------------------------------------------------------------------

const LAYOUT_CONVERSATION = 'conversation'
const LAYOUT_REVIEW = 'review'
const LAYOUT_SPLIT = 'split'

// ---------------------------------------------------------------------------
// Main SessionHeader
// ---------------------------------------------------------------------------

const SessionHeader = ({
  session,
  onEnd,
  onRename,
  onFork,
  onForkToWorktree,
  onContinueInNew,
  onTakeover,
  onRollback,
  onToggleCapabilities,
  capabilitiesOpen,
  reviewOpen = false,
  onReviewToggle,
  tokenUsage,
  layoutMode,
  onLayoutChange,
  onSearch,
}) => {
  const [, navigate] = useLocation()
  const [renaming, setRenaming] = useState(false)
  const [subPopover, setSubPopover] = useState('none')
  const [overflowOpen, setOverflowOpen] = useState(false)

  if (!session) return null

  const displayName = session.display_title || session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`
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

  // Derive layout mode from reviewOpen for backwards compatibility
  const currentLayout = layoutMode || (reviewOpen ? LAYOUT_SPLIT : LAYOUT_CONVERSATION)

  const handleLayoutSelect = (mode) => {
    if (onLayoutChange) {
      // Clicking active layout toggles back to conversation
      onLayoutChange(mode === currentLayout ? LAYOUT_CONVERSATION : mode)
    } else {
      // Fallback: toggle review panel
      if (mode === LAYOUT_REVIEW || mode === LAYOUT_SPLIT) {
        if (!reviewOpen) onReviewToggle?.()
      } else {
        if (reviewOpen) onReviewToggle?.()
      }
    }
  }

  return (
    <header class={styles.header}>
      {/* ── Leading: back + identity + badges ─────────────────────────── */}
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

        <ModelBadge model={session.model} />
        <EffortBadge effort={session.effort} />

        <span class={`${styles.statusLabel} ${styles[`status-${session.work_status}`] || ''}`}>
          {statusText}
        </span>
      </div>

      {/* ── Intelligence zone: context pills ──────────────────────────── */}
      <div class={styles.intelligence}>
        <ContextPill tokenUsage={tokenUsage} />
      </div>

      {/* ── Controls zone ─────────────────────────────────────────────── */}
      <div class={styles.controls}>
        {/* View mode toggle (focused/verbose) */}
        <div class={styles.toggleGroup}>
          <button
            class={`${styles.toggleBtn} ${viewMode.value === 'focused' ? styles.toggleBtnActive : ''}`}
            onClick={() => { if (viewMode.value !== 'focused') toggleViewMode() }}
            aria-label="Focused view — shows collapsed tool calls and compact layout"
            title="Focused view — collapsed tool calls, compact layout"
          >
            <FocusedViewIcon />
          </button>
          <button
            class={`${styles.toggleBtn} ${viewMode.value === 'verbose' ? styles.toggleBtnActive : ''}`}
            onClick={() => { if (viewMode.value !== 'verbose') toggleViewMode() }}
            aria-label="Verbose view — shows all tool details and full output"
            title="Verbose view — all tool details, full output"
          >
            <VerboseViewIcon />
          </button>
        </div>

        {/* Layout toggle (conversation / review / split) */}
        <div class={styles.toggleGroup}>
          <button
            class={`${styles.toggleBtn} ${currentLayout === LAYOUT_CONVERSATION ? styles.toggleBtnActive : ''}`}
            onClick={() => handleLayoutSelect(LAYOUT_CONVERSATION)}
            aria-label="Conversation only"
            title="Conversation"
          >
            <ConversationIcon />
          </button>
          <button
            class={`${styles.toggleBtn} ${currentLayout === LAYOUT_REVIEW ? styles.toggleBtnActive : ''}`}
            onClick={() => handleLayoutSelect(LAYOUT_REVIEW)}
            aria-label="Review only"
            title="Review"
          >
            <ReviewIcon />
          </button>
          <button
            class={`${styles.toggleBtn} ${currentLayout === LAYOUT_SPLIT ? styles.toggleBtnActive : ''}`}
            onClick={() => handleLayoutSelect(LAYOUT_SPLIT)}
            aria-label="Split view"
            title="Split — conversation + review"
          >
            <SplitIcon />
          </button>
        </div>

        {/* Tools toggle */}
        <button
          class={`${styles.iconBtn} ${capabilitiesOpen ? styles.iconBtnActive : ''}`}
          onClick={onToggleCapabilities}
          aria-label="Toggle tools panel"
          title="Tools"
        >
          <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
            <path d="M9.5 2.5l4 4-7 7H2.5v-4l7-7z" />
          </svg>
        </button>

        {/* Search / ⌘K */}
        {onSearch && (
          <button
            class={styles.iconBtn}
            onClick={onSearch}
            aria-label="Search sessions (⌘K)"
            title="Search (⌘K)"
          >
            <SearchIcon />
          </button>
        )}

        {/* Overflow trigger (mobile + session actions) */}
        {isActive && (
          <div class={styles.popoverAnchor}>
            <button
              class={styles.iconBtn}
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
              {/* Layout section — visible on mobile */}
              <div class={styles.overflowSection}>
                <span class={styles.overflowSectionLabel}>Layout</span>
                <button
                  class={`${styles.overflowItem} ${currentLayout === LAYOUT_CONVERSATION ? styles.overflowItemActive : ''}`}
                  onClick={() => { handleLayoutSelect(LAYOUT_CONVERSATION); setOverflowOpen(false) }}
                >
                  <ConversationIcon />
                  Conversation
                </button>
                <button
                  class={`${styles.overflowItem} ${currentLayout === LAYOUT_REVIEW ? styles.overflowItemActive : ''}`}
                  onClick={() => { handleLayoutSelect(LAYOUT_REVIEW); setOverflowOpen(false) }}
                >
                  <ReviewIcon />
                  Review
                </button>
                <button
                  class={`${styles.overflowItem} ${currentLayout === LAYOUT_SPLIT ? styles.overflowItemActive : ''}`}
                  onClick={() => { handleLayoutSelect(LAYOUT_SPLIT); setOverflowOpen(false) }}
                >
                  <SplitIcon />
                  Split
                </button>
              </div>

              {/* Session actions */}
              <div class={styles.overflowDivider} />
              <div class={styles.overflowSection}>
                <span class={styles.overflowSectionLabel}>Session</span>
                {showTakeover && (
                  <button class={styles.overflowItem} onClick={() => { onTakeover?.(); setOverflowOpen(false) }}>
                    Take Over
                  </button>
                )}
                <button class={styles.overflowItem} onClick={openFork}>
                  Fork…
                </button>
                {onForkToWorktree && (
                  <button class={styles.overflowItem} onClick={() => { onForkToWorktree(); setOverflowOpen(false) }}>
                    Fork to Worktree
                  </button>
                )}
                {onContinueInNew && (
                  <button class={styles.overflowItem} onClick={() => { onContinueInNew(); setOverflowOpen(false) }}>
                    Continue in New Session
                  </button>
                )}
                <button class={styles.overflowItem} onClick={openRollback}>
                  Rollback…
                </button>
              </div>

              {/* Destructive */}
              <div class={styles.overflowDivider} />
              <button
                class={`${styles.overflowItem} ${styles.overflowItemDanger}`}
                onClick={() => { onEnd?.(); setOverflowOpen(false) }}
              >
                End Session
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
