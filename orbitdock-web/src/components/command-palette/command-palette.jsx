import { useState, useEffect, useRef, useCallback } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { sessions, selected } from '../../stores/sessions.js'
import { StatusDot } from '../ui/status-dot.jsx'
import { Badge } from '../ui/badge.jsx'
import { formatRelativeTime } from '../../lib/format.js'
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
  session.custom_name || session.summary || session.first_prompt || `Session ${session.id.slice(-8)}`

const sessionSearchText = (session) => [
  session.custom_name,
  session.summary,
  session.first_prompt,
  session.project_path,
  session.repository_root,
  session.provider,
].filter(Boolean).join(' ')

// ---------------------------------------------------------------------------
// Available commands — defined statically. Context-sensitive ones (End/Compact)
// are filtered at render time based on currently selected session.
// ---------------------------------------------------------------------------
const ALL_COMMANDS = [
  {
    id: 'new-claude',
    label: 'New Claude Session',
    description: 'Start a new Claude Code session',
    requiresSession: false,
  },
  {
    id: 'new-codex',
    label: 'New Codex Session',
    description: 'Start a new Codex session',
    requiresSession: false,
  },
  {
    id: 'end-session',
    label: 'End Session',
    description: 'End the current session',
    requiresSession: true,
  },
  {
    id: 'compact-session',
    label: 'Compact Session',
    description: 'Compact the current session context',
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
]

// ---------------------------------------------------------------------------
// Result item sub-components
// ---------------------------------------------------------------------------
const SessionResult = ({ session, isActive, onSelect }) => {
  const name = sessionDisplayName(session)
  const path = session.project_path || session.repository_root

  // Format the path for display — show only the last 2 segments
  const shortPath = (() => {
    if (!path) return null
    const parts = path.replace(/\\/g, '/').split('/').filter(Boolean)
    if (parts.length <= 2) return path
    return '.../' + parts.slice(-2).join('/')
  })()

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
        <Badge variant="tool" color={`provider-${session.provider}`}>
          {session.provider}
        </Badge>
        {session.last_activity_at && (
          <span class={styles.resultTime}>{formatRelativeTime(session.last_activity_at)}</span>
        )}
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
// Main component
// ---------------------------------------------------------------------------
const CommandPalette = ({ onCreateSession }) => {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [activeIndex, setActiveIndex] = useState(0)
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

  const results = isCommandMode ? filteredCommands : filteredSessions
  const resultCount = results.length

  // Clamp activeIndex whenever the results list changes length
  const clampedIndex = resultCount === 0 ? 0 : Math.min(activeIndex, resultCount - 1)

  // Scroll the active item into view
  useEffect(() => {
    if (!listRef.current) return
    const active = listRef.current.querySelector('[aria-selected="true"]')
    if (active) active.scrollIntoView({ block: 'nearest' })
  }, [clampedIndex, results.length])

  // Focus the input when opened
  useEffect(() => {
    if (open) {
      // rAF ensures the element is visible before focus
      const frame = requestAnimationFrame(() => inputRef.current?.focus())
      return () => cancelAnimationFrame(frame)
    }
  }, [open])

  // Global Cmd+K / Ctrl+K listener — intentionally fires even inside inputs
  useEffect(() => {
    const onKeyDown = (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault()
        setOpen((v) => {
          if (v) return false // toggle closed
          return true
        })
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
          // Caller is responsible for actual end; we just navigate + close.
          // The session page already has end handlers; route there first.
          navigate(`/session/${currentSession.id}`)
        }
        break
      case 'compact-session':
        if (currentSession) {
          navigate(`/session/${currentSession.id}`)
        }
        break
      case 'settings':
        navigate('/settings')
        break
      case 'missions':
        navigate('/missions')
        break
    }
    close()
  }, [currentSession, navigate, close, onCreateSession])

  const handleSelect = useCallback((index) => {
    if (isCommandMode) {
      executeCommand(filteredCommands[index])
    } else {
      executeSession(filteredSessions[index])
    }
  }, [isCommandMode, filteredCommands, filteredSessions, executeCommand, executeSession])

  const handleKeyDown = (e) => {
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
    }
  }

  const handleInput = (e) => {
    setQuery(e.target.value)
    setActiveIndex(0)
  }

  if (!open) return null

  const placeholder = isCommandMode ? 'Type a command…' : 'Search sessions…'
  const sectionLabel = isCommandMode ? 'Commands' : (query ? 'Results' : 'Recent Sessions')

  return (
    <div class={styles.overlay} onClick={close} role="dialog" aria-modal="true" aria-label="Command palette">
      <div class={styles.panel} onClick={(e) => e.stopPropagation()}>
        <div class={styles.inputRow}>
          <span class={styles.searchIcon} aria-hidden="true">
            {isCommandMode ? '>' : '⌕'}
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
            <div class={styles.sectionLabel}>{sectionLabel}</div>
            <div
              id="command-palette-list"
              class={styles.resultList}
              ref={listRef}
              role="listbox"
              aria-label={sectionLabel}
            >
              {isCommandMode
                ? filteredCommands.map((cmd, i) => (
                    <CommandResult
                      key={cmd.id}
                      command={cmd}
                      isActive={i === clampedIndex}
                      onSelect={() => handleSelect(i)}
                    />
                  ))
                : filteredSessions.map((session, i) => (
                    <SessionResult
                      key={session.id}
                      session={session}
                      isActive={i === clampedIndex}
                      onSelect={() => handleSelect(i)}
                    />
                  ))
              }
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
          <span class={styles.hint}><kbd>esc</kbd> dismiss</span>
          <span class={styles.hintSep} />
          <span class={styles.hint}>Type <kbd>&gt;</kbd> for commands</span>
        </div>
      </div>
    </div>
  )
}

export { CommandPalette }
