import { useState, useEffect, useRef, useCallback } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { sessions, selected } from '../../stores/sessions.js'
import { StatusDot } from '../ui/status-dot.jsx'
import { Badge } from '../ui/badge.jsx'
import { formatRelativeTime } from '../../lib/format.js'
import { http } from '../../stores/connection.js'
import { addToast } from '../../stores/toasts.js'
import styles from './command-palette.module.css'

// ---------------------------------------------------------------------------
// Fuzzy match: returns true if every character in `needle` appears in `haystack`
// in order. Simple and fast enough for client-side session filtering.
// ---------------------------------------------------------------------------
const fuzzyMatch = (haystack, needle) => {
  if (!needle) return true
  const h = haystack.toLowerCase()
  const n = needle.toLowerCase()
  let hi = 0
  for (let ni = 0; ni < n.length; ni++) {
    const idx = h.indexOf(n[ni], hi)
    if (idx === -1) return false
    hi = idx + 1
  }
  return true
}

const sessionDisplayName = (session) =>
  session.display_title || session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`

const sessionSearchText = (session) => [
  session.display_title,
  session.custom_name,
  session.summary,
  session.first_prompt,
  session.context_line,
  session.project_path,
  session.repository_root,
  session.provider,
].filter(Boolean).join(' ')

// ---------------------------------------------------------------------------
// Activity description — one-line action text for session badges
// ---------------------------------------------------------------------------
const ACTIVITY_LABELS = {
  working: 'Working',
  permission: 'Awaiting approval',
  question: 'Has a question',
  waiting: 'Waiting',
}

const getActivityLabel = (session) =>
  ACTIVITY_LABELS[session?.work_status] || null

// ---------------------------------------------------------------------------
// Available commands — context-sensitive ones are filtered at render time.
// Quick launch aliases match in session search mode too.
// ---------------------------------------------------------------------------
const ALL_COMMANDS = [
  {
    id: 'new-claude',
    label: 'New Claude Session',
    description: 'Start a new Claude Code session',
    requiresSession: false,
    aliases: ['new claude', 'claude', 'new session'],
  },
  {
    id: 'new-codex',
    label: 'New Codex Session',
    description: 'Start a new Codex session',
    requiresSession: false,
    aliases: ['new codex', 'codex'],
  },
  {
    id: 'end-session',
    label: 'End Session',
    description: 'End the current session',
    requiresSession: true,
  },
  {
    id: 'compact-session',
    label: 'Compact Context',
    description: 'Compact the current session context',
    requiresSession: true,
  },
  {
    id: 'interrupt-session',
    label: 'Interrupt Agent',
    description: 'Stop the agent processing',
    requiresSession: true,
  },
  {
    id: 'resume-session',
    label: 'Resume Session',
    description: 'Resume a paused or ended session',
    requiresSession: true,
  },
  {
    id: 'fork-session',
    label: 'Fork Session',
    description: 'Fork the current conversation',
    requiresSession: true,
  },
  {
    id: 'fork-worktree',
    label: 'Fork to Worktree',
    description: 'Fork the session into a new worktree',
    requiresSession: true,
  },
  {
    id: 'settings',
    label: 'Settings',
    description: 'Open settings',
    requiresSession: false,
  },
  {
    id: 'missions',
    label: 'Missions',
    description: 'View missions',
    requiresSession: false,
  },
  {
    id: 'worktrees',
    label: 'Worktrees',
    description: 'Manage worktrees',
    requiresSession: false,
  },
  {
    id: 'keyboard-help',
    label: 'Keyboard Shortcuts',
    description: 'Show keyboard shortcuts',
    requiresSession: false,
  },
]

// Quick launch: match commands by aliases in session search mode
const getQuickLaunchCommands = (query) => {
  if (!query || query.length < 2) return []
  const lower = query.toLowerCase()
  return ALL_COMMANDS.filter((cmd) =>
    cmd.aliases?.some((alias) => alias.startsWith(lower))
  )
}

// ---------------------------------------------------------------------------
// Result item sub-components
// ---------------------------------------------------------------------------
const SessionResult = ({ session, isActive, onSelect, onRename, onEnd }) => {
  const name = sessionDisplayName(session)
  const path = session.project_path || session.repository_root

  const shortPath = (() => {
    if (!path) return null
    const parts = path.replace(/\\/g, '/').split('/').filter(Boolean)
    if (parts.length <= 2) return path
    return '.../' + parts.slice(-2).join('/')
  })()

  const activityLabel = getActivityLabel(session)
  const isWorking = session.work_status === 'working'
  const needsAttention = session.work_status === 'permission' || session.work_status === 'question'

  return (
    <button
      class={`${styles.result} ${isActive ? styles.resultActive : ''}`}
      onClick={onSelect}
      role="option"
      aria-selected={isActive}
    >
      <div class={styles.resultIcon}>
        <StatusDot status={session.work_status} />
      </div>
      <div class={styles.resultBody}>
        <span class={styles.resultLabel}>{name}</span>
        {shortPath && (
          <span class={styles.resultMeta}>{shortPath}</span>
        )}
      </div>
      <div class={styles.resultRight}>
        {/* Activity badge */}
        {activityLabel && (
          <span class={`${styles.activityBadge} ${needsAttention ? styles.activityAttention : ''} ${isWorking ? styles.activityWorking : ''}`}>
            {activityLabel}
          </span>
        )}
        <Badge variant="tool" color={`provider-${session.provider}`}>
          {session.provider}
        </Badge>
        {session.last_activity_at && (
          <span class={styles.resultTime}>{formatRelativeTime(session.last_activity_at)}</span>
        )}
        {/* Hover-reveal actions */}
        <div class={styles.hoverActions} onClick={(e) => e.stopPropagation()}>
          <button
            class={styles.hoverAction}
            onClick={(e) => { e.stopPropagation(); onRename?.(session) }}
            title="Rename"
            aria-label="Rename session"
          >
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
              <path d="M7 2l3 3-7 7H0V9l7-7z" />
            </svg>
          </button>
          <button
            class={`${styles.hoverAction} ${styles.hoverActionDanger}`}
            onClick={(e) => { e.stopPropagation(); onEnd?.(session) }}
            title="End session"
            aria-label="End session"
          >
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round">
              <path d="M2 2l8 8M10 2l-8 8" />
            </svg>
          </button>
        </div>
      </div>
    </button>
  )
}

const CommandResult = ({ command, isActive, onSelect }) => (
  <button
    class={`${styles.result} ${isActive ? styles.resultActive : ''}`}
    onClick={onSelect}
    role="option"
    aria-selected={isActive}
  >
    <div class={styles.resultIcon}>
      <span class={styles.commandGlyph}>&gt;</span>
    </div>
    <div class={styles.resultBody}>
      <span class={styles.resultLabel}>{command.label}</span>
      {command.description && (
        <span class={styles.resultMeta}>{command.description}</span>
      )}
    </div>
  </button>
)

// ---------------------------------------------------------------------------
// Inline rename overlay
// ---------------------------------------------------------------------------
const RenameOverlay = ({ session, onSave, onCancel }) => {
  const [draft, setDraft] = useState(sessionDisplayName(session))
  const inputRef = useRef(null)

  useEffect(() => {
    const frame = requestAnimationFrame(() => inputRef.current?.select())
    return () => cancelAnimationFrame(frame)
  }, [])

  const commit = () => {
    const trimmed = draft.trim()
    if (trimmed && trimmed !== sessionDisplayName(session)) {
      onSave(session, trimmed)
    } else {
      onCancel()
    }
  }

  return (
    <div class={styles.renameBody}>
      <div class={styles.renameRow}>
        <StatusDot status={session.work_status} />
        <input
          ref={inputRef}
          class={styles.renameInput}
          value={draft}
          onInput={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') { e.preventDefault(); commit() }
            else if (e.key === 'Escape') { e.preventDefault(); onCancel() }
          }}
          onBlur={commit}
          placeholder="Session name"
        />
      </div>
      <span class={styles.renameHint}>Press Enter to save, Esc to cancel</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Main component
// ---------------------------------------------------------------------------
const CommandPalette = ({ onCreateSession, onShowKeyboardHelp }) => {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [activeIndex, setActiveIndex] = useState(0)
  const [renameSession, setRenameSession] = useState(null)
  const [, navigate] = useLocation()
  const inputRef = useRef(null)
  const listRef = useRef(null)

  const isCommandMode = query.startsWith('>')
  const searchQuery = isCommandMode ? query.slice(1).trimStart() : query

  // Derive the flat session list sorted by most-recently active first
  const sortedSessions = [...sessions.value.values()].sort((a, b) => {
    const ta = a.last_activity_at ? new Date(a.last_activity_at).getTime() : 0
    const tb = b.last_activity_at ? new Date(b.last_activity_at).getTime() : 0
    return tb - ta
  })

  const currentSession = selected.value

  const filteredSessions = isCommandMode
    ? []
    : sortedSessions.filter((s) => fuzzyMatch(sessionSearchText(s), searchQuery))

  const filteredCommands = isCommandMode
    ? ALL_COMMANDS.filter((cmd) => {
        if (cmd.requiresSession && !currentSession) return false
        return fuzzyMatch(cmd.label + ' ' + (cmd.description || ''), searchQuery)
      })
    : []

  // Quick launch: show matching commands in session search mode
  const quickLaunchCommands = isCommandMode ? [] : getQuickLaunchCommands(searchQuery)

  const quickLaunchCount = quickLaunchCommands.length
  const sessionCount = filteredSessions.length
  const commandCount = filteredCommands.length
  const resultCount = isCommandMode ? commandCount : quickLaunchCount + sessionCount

  // Clamp activeIndex whenever the results list changes length
  const clampedIndex = resultCount === 0 ? 0 : Math.min(activeIndex, resultCount - 1)

  // Scroll the active item into view
  useEffect(() => {
    if (!listRef.current) return
    const active = listRef.current.querySelector('[aria-selected="true"]')
    if (active) active.scrollIntoView({ block: 'nearest' })
  }, [clampedIndex, resultCount])

  // Focus the input when opened
  useEffect(() => {
    if (open) {
      const frame = requestAnimationFrame(() => inputRef.current?.focus())
      return () => cancelAnimationFrame(frame)
    }
  }, [open])

  // Global Cmd+K / Ctrl+K listener
  useEffect(() => {
    const onKeyDown = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault()
        setOpen((v) => !v)
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  // Reset state when closed
  useEffect(() => {
    if (!open) {
      setQuery('')
      setActiveIndex(0)
      setRenameSession(null)
    }
  }, [open])

  const close = useCallback(() => setOpen(false), [])

  const executeSession = useCallback((session) => {
    navigate(`/session/${session.id}`)
    close()
  }, [navigate, close])

  const executeCommand = useCallback((cmd) => {
    switch (cmd.id) {
      case 'new-claude':
        onCreateSession?.('claude')
        break
      case 'new-codex':
        onCreateSession?.('codex')
        break
      case 'end-session':
        if (currentSession) {
          http.post(`/api/sessions/${currentSession.id}/end`).catch((err) => {
            addToast({ title: 'End failed', body: err.message, type: 'error' })
          })
        }
        break
      case 'compact-session':
        if (currentSession) {
          http.post(`/api/sessions/${currentSession.id}/compact`).catch((err) => {
            addToast({ title: 'Compact failed', body: err.message, type: 'error' })
          })
        }
        break
      case 'interrupt-session':
        if (currentSession) {
          http.post(`/api/sessions/${currentSession.id}/interrupt`)
        }
        break
      case 'resume-session':
        if (currentSession) {
          http.post(`/api/sessions/${currentSession.id}/resume`).catch((err) => {
            addToast({ title: 'Resume failed', body: err.message, type: 'error' })
          })
        }
        break
      case 'fork-session':
        if (currentSession) {
          http.post(`/api/sessions/${currentSession.id}/fork`).then((res) => {
            if (res?.session?.id) navigate(`/session/${res.session.id}`)
          }).catch((err) => {
            addToast({ title: 'Fork failed', body: err.message, type: 'error' })
          })
        }
        break
      case 'fork-worktree':
        if (currentSession) {
          http.post(`/api/sessions/${currentSession.id}/fork-to-worktree`).then((res) => {
            if (res?.session?.id) navigate(`/session/${res.session.id}`)
          }).catch((err) => {
            addToast({ title: 'Fork to worktree failed', body: err.message, type: 'error' })
          })
        }
        break
      case 'settings':
        navigate('/settings')
        break
      case 'missions':
        navigate('/missions')
        break
      case 'worktrees':
        navigate('/worktrees')
        break
      case 'keyboard-help':
        onShowKeyboardHelp?.()
        break
    }
    close()
  }, [currentSession, navigate, close, onCreateSession, onShowKeyboardHelp])

  const handleSelect = useCallback((index) => {
    if (isCommandMode) {
      executeCommand(filteredCommands[index])
    } else if (index < quickLaunchCount) {
      executeCommand(quickLaunchCommands[index])
    } else {
      executeSession(filteredSessions[index - quickLaunchCount])
    }
  }, [isCommandMode, filteredCommands, filteredSessions, quickLaunchCommands, quickLaunchCount, executeCommand, executeSession])

  const handleRename = (session) => setRenameSession(session)

  const handleRenameSave = (session, newName) => {
    http.patch(`/api/sessions/${session.id}/name`, { name: newName }).catch((err) => {
      addToast({ title: 'Rename failed', body: err.message, type: 'error' })
    })
    setRenameSession(null)
  }

  const handleEndSession = (session) => {
    http.post(`/api/sessions/${session.id}/end`).catch((err) => {
      addToast({ title: 'End failed', body: err.message, type: 'error' })
    })
  }

  const handleKeyDown = (e) => {
    if (renameSession) return

    switch (e.key) {
      case 'Escape':
        e.preventDefault()
        close()
        break
      case 'ArrowDown':
        e.preventDefault()
        setActiveIndex((i) => (i + 1) % Math.max(1, resultCount))
        break
      case 'ArrowUp':
        e.preventDefault()
        setActiveIndex((i) => (i - 1 + Math.max(1, resultCount)) % Math.max(1, resultCount))
        break
      case 'Enter':
        e.preventDefault()
        if (resultCount > 0) handleSelect(clampedIndex)
        break
      case 'F2': {
        // Inline rename on selected session
        const sessionIdx = clampedIndex - quickLaunchCount
        if (!isCommandMode && sessionIdx >= 0 && filteredSessions[sessionIdx]) {
          e.preventDefault()
          handleRename(filteredSessions[sessionIdx])
        }
        break
      }
    }

    // Cmd+R / Ctrl+R for rename
    if ((e.metaKey || e.ctrlKey) && e.key === 'r') {
      const sessionIdx = clampedIndex - quickLaunchCount
      if (!isCommandMode && sessionIdx >= 0 && filteredSessions[sessionIdx]) {
        e.preventDefault()
        handleRename(filteredSessions[sessionIdx])
      }
    }
  }

  const handleInput = (e) => {
    setQuery(e.target.value)
    setActiveIndex(0)
  }

  if (!open) return null

  const placeholder = isCommandMode ? 'Type a command…' : 'Search sessions or type "new" to create…'

  // Rename mode: show rename overlay instead of normal content
  if (renameSession) {
    return (
      <div class={styles.overlay} onClick={close} role="dialog" aria-modal="true" aria-label="Rename session">
        <div class={styles.panel} onClick={(e) => e.stopPropagation()}>
          <div class={styles.inputRow}>
            <span class={styles.searchIcon} aria-hidden="true">
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
                <path d="M8 2l4 4-8 8H0V10l8-8z" />
              </svg>
            </span>
            <span class={styles.renameTitle}>Rename Session</span>
            <kbd class={styles.escHint}>esc</kbd>
          </div>
          <RenameOverlay
            session={renameSession}
            onSave={handleRenameSave}
            onCancel={() => setRenameSession(null)}
          />
        </div>
      </div>
    )
  }

  return (
    <div class={styles.overlay} onClick={close} role="dialog" aria-modal="true" aria-label="Command palette">
      <div class={styles.panel} onClick={(e) => e.stopPropagation()}>
        <div class={styles.inputRow}>
          <span class={styles.searchIcon} aria-hidden="true">
            {isCommandMode ? '>' : (
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
                <circle cx="6" cy="6" r="4" />
                <path d="M9 9l3.5 3.5" />
              </svg>
            )}
          </span>
          <input
            ref={inputRef}
            class={styles.input}
            type="text"
            value={query}
            onInput={handleInput}
            onKeyDown={handleKeyDown}
            placeholder={placeholder}
            autocomplete="off"
            spellcheck={false}
            role="combobox"
            aria-expanded={open}
            aria-autocomplete="list"
            aria-controls="command-palette-list"
            aria-activedescendant={resultCount > 0 ? `cp-result-${clampedIndex}` : undefined}
          />
          <kbd class={styles.escHint}>esc</kbd>
        </div>

        {resultCount > 0 && (
          <div class={styles.results}>
            <div
              id="command-palette-list"
              class={styles.resultList}
              ref={listRef}
              role="listbox"
              aria-label="Results"
            >
              {/* Quick launch commands (session search mode) */}
              {quickLaunchCount > 0 && (
                <>
                  <div class={styles.sectionLabel}>Quick Launch</div>
                  {quickLaunchCommands.map((cmd, i) => (
                    <CommandResult
                      key={cmd.id}
                      command={cmd}
                      isActive={i === clampedIndex}
                      onSelect={() => handleSelect(i)}
                    />
                  ))}
                </>
              )}

              {/* Command mode results */}
              {isCommandMode && (
                <>
                  <div class={styles.sectionLabel}>Commands</div>
                  {filteredCommands.map((cmd, i) => (
                    <CommandResult
                      key={cmd.id}
                      command={cmd}
                      isActive={i === clampedIndex}
                      onSelect={() => handleSelect(i)}
                    />
                  ))}
                </>
              )}

              {/* Session results */}
              {!isCommandMode && sessionCount > 0 && (
                <>
                  <div class={styles.sectionLabel}>{query ? 'Sessions' : 'Recent Sessions'}</div>
                  {filteredSessions.map((session, i) => (
                    <SessionResult
                      key={session.id}
                      session={session}
                      isActive={(i + quickLaunchCount) === clampedIndex}
                      onSelect={() => handleSelect(i + quickLaunchCount)}
                      onRename={handleRename}
                      onEnd={handleEndSession}
                    />
                  ))}
                </>
              )}
            </div>
          </div>
        )}

        {resultCount === 0 && query && (
          <div class={styles.empty}>
            {isCommandMode ? 'No matching commands' : 'No matching sessions'}
          </div>
        )}

        <div class={styles.footer}>
          <span class={styles.hint}><kbd>↑↓</kbd> navigate</span>
          <span class={styles.hint}><kbd>↵</kbd> open</span>
          <span class={styles.hint}><kbd>F2</kbd> rename</span>
          <span class={styles.hint}><kbd>esc</kbd> dismiss</span>
          <span class={styles.hintSep} />
          <span class={styles.hint}>Type <kbd>&gt;</kbd> for commands</span>
        </div>
      </div>
    </div>
  )
}

export { CommandPalette }
