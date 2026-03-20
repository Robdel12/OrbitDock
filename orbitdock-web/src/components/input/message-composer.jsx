import { useState, useRef, useEffect, useCallback } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import { MentionCompletions } from './mention-completions.jsx'
import { SlashCompletions } from './slash-completions.jsx'
import { SkillCompletions } from './skill-completions.jsx'
import { addToast } from '../../stores/toasts.js'
import { http } from '../../stores/connection.js'
import { saveDraft, loadDraft, clearDraft } from '../../lib/draft-store.js'
import styles from './message-composer.module.css'

// ── Unique ID generator ──────────────────────────────────────────────────────
// crypto.randomUUID requires a secure context (HTTPS or localhost).
// Fall back to a simple random ID for LAN / HTTP access.
const uniqueId = () => {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    try { return crypto.randomUUID() } catch (_) { /* fall through */ }
  }
  return 'id-' + Math.random().toString(36).slice(2) + Date.now().toString(36)
}

// ── Image helpers ────────────────────────────────────────────────────────────

const extractImageFiles = (dataTransfer) => {
  const files = []
  if (dataTransfer.items) {
    for (const item of dataTransfer.items) {
      if (item.kind === 'file' && item.type.startsWith('image/')) {
        const file = item.getAsFile()
        if (file) files.push(file)
      }
    }
  } else {
    for (const file of dataTransfer.files) {
      if (file.type.startsWith('image/')) files.push(file)
    }
  }
  return files
}

const readAsDataUrl = (file) =>
  new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(file)
  })

const MAX_IMAGES = 5
const MAX_IMAGE_SIZE = 10 * 1024 * 1024   // 10 MB
const MAX_TOTAL_SIZE = 50 * 1024 * 1024    // 50 MB

const filesToAttachments = async (files) =>
  Promise.all(
    files.map(async (file) => {
      const dataUrl = await readAsDataUrl(file)
      return { id: uniqueId(), dataUrl, mimeType: file.type, name: file.name, size: file.size }
    })
  )

// ── Contenteditable helpers ──────────────────────────────────────────────────

// Insert plain text into a contenteditable element while preserving undo history.
// execCommand is deprecated but there is no standard replacement for contenteditable
// insertText that preserves the browser undo stack.
const insertTextAtCursor = (text) => {
  document.execCommand('insertText', false, text)
}

const getPlainText = (el) => {
  if (!el) return ''
  return el.innerText || ''
}

const getCursorOffset = (el) => {
  const sel = window.getSelection()
  if (!sel.rangeCount || !el.contains(sel.focusNode)) return 0
  const range = document.createRange()
  range.selectNodeContents(el)
  range.setEnd(sel.focusNode, sel.focusOffset)
  return range.toString().length
}

const setCursorOffset = (el, offset) => {
  const sel = window.getSelection()
  const range = document.createRange()

  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null)
  let remaining = offset
  let node = walker.nextNode()

  while (node) {
    if (remaining <= node.textContent.length) {
      range.setStart(node, remaining)
      range.collapse(true)
      sel.removeAllRanges()
      sel.addRange(range)
      return
    }
    remaining -= node.textContent.length
    node = walker.nextNode()
  }

  range.selectNodeContents(el)
  range.collapse(false)
  sel.removeAllRanges()
  sel.addRange(range)
}

// ── Token formatting ─────────────────────────────────────────────────────────

const formatK = (n) => n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n)

const formatTokenUsage = (usage) => {
  if (!usage) return null
  const total = (usage.input_tokens || 0) + (usage.output_tokens || 0)
  if (total === 0) return null
  const ctxTotal = usage.context_window_total || 0
  const pct = ctxTotal ? Math.round((total / ctxTotal) * 100) : null
  const display = ctxTotal
    ? `${formatK(total)}/${formatK(ctxTotal)}`
    : formatK(total)
  return { display, pct }
}

const tokenColorClass = (pct) => {
  if (pct == null) return ''
  if (pct >= 90) return styles.tokenDanger
  if (pct >= 70) return styles.tokenWarning
  return ''
}

// ── Workflow overflow menu ────────────────────────────────────────────────────

const WorkflowMenu = ({ open, onClose, onUndo, onFork, onForkToWorktree, onContinueInNew, onCompact, isActive, shellMode, onToggleShell }) => {
  if (!open) return null

  return (
    <div class={styles.overflowMenu} onClick={(e) => e.stopPropagation()}>
      <div class={styles.overflowSection}>
        <span class={styles.overflowSectionLabel}>Turn</span>
        <button class={styles.overflowItem} disabled={!isActive} onClick={() => { onUndo(); onClose() }}>
          Undo Last Turn
        </button>
        <button class={styles.overflowItem} disabled={!isActive} onClick={() => { onCompact(); onClose() }}>
          Compact Context
        </button>
      </div>
      <div class={styles.overflowDivider} />
      <div class={styles.overflowSection}>
        <span class={styles.overflowSectionLabel}>Session</span>
        <button class={styles.overflowItem} disabled={!isActive} onClick={() => { onFork(); onClose() }}>
          Fork Conversation
        </button>
        {onForkToWorktree && (
          <button class={styles.overflowItem} disabled={!isActive} onClick={() => { onForkToWorktree(); onClose() }}>
            Fork to Worktree
          </button>
        )}
        {onContinueInNew && (
          <button class={styles.overflowItem} disabled={!isActive} onClick={() => { onContinueInNew(); onClose() }}>
            Continue in New Session
          </button>
        )}
      </div>
      {onToggleShell && (
        <>
          <div class={styles.overflowDivider} />
          <div class={styles.overflowSection}>
            <span class={styles.overflowSectionLabel}>Mode</span>
            <button class={styles.overflowItem} onClick={() => { onToggleShell(); onClose() }}>
              {shellMode ? 'Disable Shell Mode' : 'Enable Shell Mode'}
            </button>
          </div>
        </>
      )}
    </div>
  )
}

// ── Model/effort popover ─────────────────────────────────────────────────

const EFFORT_OPTIONS = [
  { value: 'low', label: 'Low' },
  { value: 'medium', label: 'Medium' },
  { value: 'high', label: 'High' },
]

const shortModelName = (model) => {
  if (!model) return null
  const lower = model.toLowerCase()
  if (lower.includes('opus')) return 'Opus'
  if (lower.includes('sonnet')) return 'Sonnet'
  if (lower.includes('haiku')) return 'Haiku'
  if (lower.includes('gpt-4o-mini')) return '4o-mini'
  if (lower.includes('gpt-4o')) return 'GPT-4o'
  if (lower.includes('gpt-4')) return 'GPT-4'
  if (lower.includes('o3')) return 'o3'
  if (lower.includes('o1')) return 'o1'
  // Fallback: last segment after dash
  const parts = model.split('-')
  return parts[parts.length - 1]
}

const ModelEffortPopover = ({ open, onClose, provider, models, currentModel, onModelChange, effort, onEffortChange }) => {
  if (!open) return null

  return (
    <div class={styles.modelPopover} onClick={(e) => e.stopPropagation()}>
      {/* Model selection */}
      <div class={styles.overflowSection}>
        <span class={styles.overflowSectionLabel}>Model</span>
        {models.length === 0 && (
          <span class={styles.modelEmpty}>Loading models…</span>
        )}
        {models.map((m) => {
          const id = m.value || m.id || m.model
          const display = m.display_name || m.label || id
          const isActive = id === currentModel
          return (
            <button
              key={id}
              class={`${styles.overflowItem} ${isActive ? styles.modelItemActive : ''}`}
              onClick={() => { onModelChange(id); onClose() }}
            >
              <span class={styles.modelItemLabel}>{display}</span>
              {isActive && (
                <svg class={styles.modelCheck} width="12" height="12" viewBox="0 0 12 12" fill="none">
                  <path d="M2.5 6l2.5 2.5 4.5-5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
                </svg>
              )}
            </button>
          )
        })}
      </div>

      {/* Effort picker for Codex */}
      {provider === 'codex' && (
        <>
          <div class={styles.overflowDivider} />
          <div class={styles.overflowSection}>
            <span class={styles.overflowSectionLabel}>Effort</span>
            <div class={styles.effortPicker}>
              {EFFORT_OPTIONS.map((opt) => (
                <button
                  key={opt.value}
                  class={`${styles.effortOption} ${effort === opt.value ? styles.effortOptionActive : ''}`}
                  onClick={() => onEffortChange(opt.value)}
                >
                  {opt.label}
                </button>
              ))}
            </div>
          </div>
        </>
      )}
    </div>
  )
}

// ── SVG Icons ────────────────────────────────────────────────────────────────

const StopIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
    <rect x="1.5" y="1.5" width="9" height="9" rx="1.5" fill="currentColor" />
  </svg>
)

const ImageIcon = () => (
  <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
    <rect x="1" y="3" width="12" height="9" rx="1.5" stroke="currentColor" stroke-width="1.2" />
    <circle cx="4.5" cy="6.5" r="1" fill="currentColor" />
    <path d="M1.5 10l3-3 2 2 2.5-3L13 10.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
)

const MentionIcon = () => (
  <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
    <circle cx="7" cy="7" r="3" stroke="currentColor" stroke-width="1.2" />
    <path d="M10 7c0 1.66-.67 3-2 3s-1.5-1-1.5-1" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
    <path d="M10 10c1.2-1 2-2.5 2-4a5 5 0 10-2.5 4.33" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
  </svg>
)

const CommandIcon = () => (
  <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
    <path d="M4 10l3-3-3-3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round" />
    <path d="M8 10h3" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
  </svg>
)

const MoreIcon = () => (
  <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
    <circle cx="3" cy="7" r="1.2" fill="currentColor" />
    <circle cx="7" cy="7" r="1.2" fill="currentColor" />
    <circle cx="11" cy="7" r="1.2" fill="currentColor" />
  </svg>
)

const TuneIcon = () => (
  <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round">
    <line x1="2" y1="4" x2="12" y2="4" />
    <line x1="2" y1="10" x2="12" y2="10" />
    <circle cx="5" cy="4" r="1.5" fill="var(--color-bg-secondary)" />
    <circle cx="9" cy="10" r="1.5" fill="var(--color-bg-secondary)" />
  </svg>
)

const SendIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
    <path d="M6 10V2M6 2L2.5 5.5M6 2l3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
  </svg>
)

const SteerIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
    <path d="M2 8.5c1.5-1 3-4.5 4-5.5 1 1 2.5 4.5 4 5.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
    <path d="M6 3v5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
  </svg>
)

const PinIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
    <path d="M6 2v8M3 7l3 3 3-3" />
  </svg>
)

const PauseIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
    <rect x="2.5" y="2" width="2.5" height="8" rx="0.5" fill="currentColor" />
    <rect x="7" y="2" width="2.5" height="8" rx="0.5" fill="currentColor" />
  </svg>
)

const GitBranchIcon = () => (
  <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <circle cx="5" cy="4" r="1.5" />
    <circle cx="5" cy="12" r="1.5" />
    <circle cx="11" cy="6" r="1.5" />
    <path d="M5 5.5v5M11 7.5c0 2-2 2.5-6 3" />
  </svg>
)

const FolderIcon = () => (
  <svg width="10" height="10" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">
    <path d="M2 4v8a1 1 0 001 1h10a1 1 0 001-1V6a1 1 0 00-1-1H8L6.5 3H3a1 1 0 00-1 1z" />
  </svg>
)

// ── MessageComposer ──────────────────────────────────────────────────────────

const TerminalIcon = () => (
  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <polyline points="4 17 10 11 4 5" /><line x1="12" y1="19" x2="20" y2="19" />
  </svg>
)

const MessageComposer = ({
  sessionId,
  onSend,
  onSteer,
  onShellExec,
  onInterrupt,
  onResume,
  onContinueInNew,
  onUndo,
  onFork,
  onForkToWorktree,
  onCompact,
  onEnd,
  disabled,
  isWorking,
  isPending,
  isEnded,
  isConnected,
  provider,
  approvalPolicy,
  onApprovalPolicyChange,
  projectPath,
  skills,
  session,
  tokenUsage,
  isPinned,
  unreadCount,
  onScrollToBottom,
  onModelChange,
}) => {
  const [value, setValue] = useState('')
  const [attachments, setAttachments] = useState([])
  const [dragOver, setDragOver] = useState(false)
  const [effort, setEffort] = useState('medium')
  const [cursorPos, setCursorPos] = useState(0)
  const [focused, setFocused] = useState(false)
  const [workflowOpen, setWorkflowOpen] = useState(false)
  const [shellMode, setShellMode] = useState(false)
  const [modelPopoverOpen, setModelPopoverOpen] = useState(false)
  const [availableModels, setAvailableModels] = useState([])
  const editorRef = useRef(null)
  const fileInputRef = useRef(null)
  const mentionRef = useRef(null)
  const slashRef = useRef(null)
  const skillRef = useRef(null)
  const workflowRef = useRef(null)
  const modelRef = useRef(null)
  // Guard against recursive sync between state and DOM.
  const suppressSync = useRef(false)

  // Determine if we're in steer mode
  const isSteering = isWorking && !!value.trim() && !attachments.length

  // Restore draft when switching sessions.
  useEffect(() => {
    const draft = loadDraft(sessionId)
    setValue(draft || '')
    if (editorRef.current) {
      editorRef.current.textContent = draft || ''
    }
  }, [sessionId])

  // Sync value → DOM when state changes externally (e.g. completion insert).
  useEffect(() => {
    if (suppressSync.current) {
      suppressSync.current = false
      return
    }
    const el = editorRef.current
    if (!el) return
    if (getPlainText(el) !== value) {
      el.textContent = value
      setCursorOffset(el, cursorPos)
    }
  }, [value])

  // Close workflow menu on outside click
  useEffect(() => {
    if (!workflowOpen) return
    const handleClick = (e) => {
      if (workflowRef.current && !workflowRef.current.contains(e.target)) {
        setWorkflowOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [workflowOpen])

  // Close model popover on outside click
  useEffect(() => {
    if (!modelPopoverOpen) return
    const handleClick = (e) => {
      if (modelRef.current && !modelRef.current.contains(e.target)) {
        setModelPopoverOpen(false)
      }
    }
    document.addEventListener('mousedown', handleClick)
    return () => document.removeEventListener('mousedown', handleClick)
  }, [modelPopoverOpen])

  // Fetch available models when the popover opens
  useEffect(() => {
    if (!modelPopoverOpen || !provider) return
    const endpoint = provider === 'codex' ? '/api/models/codex' : '/api/models/claude'
    http.get(endpoint).then((res) => {
      setAvailableModels(res?.models || [])
    }).catch(() => {
      // Silently fail — the popover will show "Loading models…"
    })
  }, [modelPopoverOpen, provider])

  const syncFromDom = useCallback(() => {
    const el = editorRef.current
    if (!el) return
    const text = getPlainText(el)
    const pos = getCursorOffset(el)
    suppressSync.current = true
    setValue(text)
    setCursorPos(pos)
    saveDraft(sessionId, text)
  }, [sessionId])

  const handleInput = () => syncFromDom()

  // Insert a completion at [start, end] in the value.
  const handleInsert = (start, end, text) => {
    const before = value.slice(0, start)
    const after = value.slice(end)
    const next = before + text + after
    const pos = start + text.length
    setValue(next)
    setCursorPos(pos)
    saveDraft(sessionId, next)
    const el = editorRef.current
    if (el) {
      el.textContent = next
      el.focus()
      requestAnimationFrame(() => setCursorOffset(el, pos))
    }
  }

  const addFiles = async (files) => {
    if (!files.length) return

    const validFiles = files.filter((f) => f.size <= MAX_IMAGE_SIZE)
    if (validFiles.length < files.length) {
      addToast({ title: 'Image too large', body: 'Images must be under 10 MB', type: 'error' })
    }

    const remaining = MAX_IMAGES - attachments.length
    const toAdd = validFiles.slice(0, Math.max(0, remaining))
    if (toAdd.length < validFiles.length && remaining > 0) {
      addToast({ title: 'Too many images', body: `Maximum ${MAX_IMAGES} images per message`, type: 'error' })
    } else if (remaining <= 0) {
      addToast({ title: 'Too many images', body: `Maximum ${MAX_IMAGES} images per message`, type: 'error' })
      return
    }

    if (!toAdd.length) return

    try {
      const newAttachments = await filesToAttachments(toAdd)
      const currentSize = attachments.reduce((sum, a) => sum + (a.size || 0), 0)
      const filtered = []
      let runningSize = currentSize
      for (const att of newAttachments) {
        if (runningSize + (att.size || 0) <= MAX_TOTAL_SIZE) {
          filtered.push(att)
          runningSize += att.size || 0
        } else {
          addToast({ title: 'Total size exceeded', body: 'Attachments exceed 50 MB limit', type: 'error' })
          break
        }
      }
      if (filtered.length) {
        setAttachments((prev) => [...prev, ...filtered])
      }
    } catch (err) {
      console.warn('[composer] failed to process images:', err)
      addToast({ title: 'Image error', body: 'Failed to process pasted image', type: 'error' })
    }
  }

  const removeAttachment = (id) => {
    setAttachments((prev) => prev.filter((a) => a.id !== id))
  }

  const handlePaste = (e) => {
    const files = extractImageFiles(e.clipboardData)
    if (files.length) {
      e.preventDefault()
      addFiles(files)
      return
    }
    // For text paste, prevent rich content — insert as plain text.
    const text = e.clipboardData.getData('text/plain')
    if (text) {
      e.preventDefault()
      insertTextAtCursor(text)
    }
  }

  const handleDragOver = (e) => {
    e.preventDefault()
    setDragOver(true)
  }

  const handleDragLeave = (e) => {
    if (!e.currentTarget.contains(e.relatedTarget)) {
      setDragOver(false)
    }
  }

  const handleDrop = (e) => {
    e.preventDefault()
    setDragOver(false)
    const files = extractImageFiles(e.dataTransfer)
    addFiles(files)
  }

  const handleFileInput = (e) => {
    const files = Array.from(e.target.files).filter((f) => f.type.startsWith('image/'))
    addFiles(files)
    e.target.value = ''
  }

  const handleSubmit = (e) => {
    if (e) e.preventDefault()
    const text = value.trim()
    if ((!text && !attachments.length) || disabled) return

    // Shell mode — send as shell command and exit shell mode
    if (shellMode && onShellExec && text) {
      onShellExec(text)
      setValue('')
      setShellMode(false)
      clearDraft(sessionId)
      if (editorRef.current) editorRef.current.textContent = ''
      return
    }

    // Inline shell shortcut: ! prefix runs a one-off shell command
    if (text.startsWith('!') && text.length > 1 && onShellExec && !attachments.length) {
      onShellExec(text.slice(1))
      setValue('')
      clearDraft(sessionId)
      if (editorRef.current) editorRef.current.textContent = ''
      return
    }

    // When the agent is actively working, steer the current turn instead of
    // queuing a new user message — unless there's no steer handler.
    if (isWorking && onSteer && text && !attachments.length) {
      onSteer(text)
      setValue('')
      clearDraft(sessionId)
      if (editorRef.current) {
        editorRef.current.textContent = ''
      }
      return
    }

    const payload = { content: text }
    if (attachments.length) {
      payload.images = attachments.map(({ dataUrl, mimeType, name }) => ({
        input_type: 'url',
        value: dataUrl,
        mime_type: mimeType,
        display_name: name,
      }))
    }
    if (provider === 'codex') {
      payload.effort = effort
    }

    onSend(payload)
    setValue('')
    setAttachments([])
    clearDraft(sessionId)
    if (editorRef.current) {
      editorRef.current.textContent = ''
    }
  }

  const handleKeyDown = (e) => {
    if (skillRef.current?.handleKeyDown(e)) return
    if (mentionRef.current?.handleKeyDown(e)) return
    if (slashRef.current?.handleKeyDown(e)) return

    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSubmit()
    }
  }

  const handleSelect = () => {
    const el = editorRef.current
    if (el) setCursorPos(getCursorOffset(el))
  }

  const canSend = (value.trim() || attachments.length > 0) && !disabled

  // ── Token display ──────────────────────────────────────────────────────────

  const tokenInfo = formatTokenUsage(tokenUsage)
  const model = session?.model
  const branch = session?.branch
  const cwd = session?.project_path || session?.repository_root
  const cwdLabel = cwd ? cwd.split('/').filter(Boolean).slice(-1)[0] : null
  const isActive = session?.status === 'active'
  const showStatusBar = isConnected === false || provider || tokenInfo || model || branch || cwdLabel

  // ── Slash command action dispatch ───────────────────────────────────────────

  const handleSlashAction = useCallback((action) => {
    const actions = {
      compact: onCompact,
      undo: onUndo,
      resume: onResume,
      fork: () => onFork?.(),
      end: onEnd,
      shell: onShellExec ? () => setShellMode((v) => !v) : null,
    }
    const handler = actions[action]
    if (handler) handler()
  }, [onCompact, onUndo, onResume, onFork, onEnd, onShellExec])

  // ── Ended state ────────────────────────────────────────────────────────────

  if (isEnded) {
    return (
      <div class={styles.resumeBar}>
        <div class={styles.resumeContent}>
          <svg class={styles.resumeIcon} width="20" height="20" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="10" cy="10" r="8" />
            <path d="M7 10l2 2 4-4" />
          </svg>
          <div class={styles.resumeText}>
            <span class={styles.resumeTitle}>Mission Complete</span>
            <span class={styles.resumeSubtitle}>This session has ended. Resume to continue working.</span>
          </div>
        </div>
        <div class={styles.resumeActions}>
          <Button variant="primary" size="sm" type="button" onClick={onResume}>
            Resume Session
          </Button>
          {onContinueInNew && (
            <Button variant="ghost" size="sm" type="button" onClick={onContinueInNew}>
              Continue in New
            </Button>
          )}
        </div>
      </div>
    )
  }

  // ── Compose state ──────────────────────────────────────────────────────────

  return (
    <form
      class={styles.composer}
      onSubmit={handleSubmit}
      onDragOver={handleDragOver}
      onDragLeave={handleDragLeave}
      onDrop={handleDrop}
    >
      {/* Shell mode indicator above the surface */}
      {shellMode && (
        <div class={styles.shellStrip}>
          <TerminalIcon />
          <span class={styles.shellLabel}>Shell Command</span>
          <button
            type="button"
            class={styles.shellExit}
            onClick={() => setShellMode(false)}
          >
            Exit
          </button>
        </div>
      )}

      {/* Steer mode indicator above the surface */}
      {isSteering && !shellMode && (
        <div class={styles.steerStrip}>
          <span class={styles.steerDot} />
          <span class={styles.steerLabel}>Steering Active Turn</span>
        </div>
      )}

      {/* Attachment bar above the surface */}
      {attachments.length > 0 && (
        <div class={styles.attachmentBar}>
          <div class={styles.attachmentHeader}>
            <span class={styles.attachmentCount}>
              {attachments.length} image{attachments.length !== 1 ? 's' : ''}
            </span>
          </div>
          <div class={styles.attachmentScroll}>
            {attachments.map((att) => (
              <div key={att.id} class={styles.attachmentCard}>
                <img src={att.dataUrl} alt={att.name} class={styles.attachmentImg} />
                <button
                  type="button"
                  class={styles.attachmentRemove}
                  onClick={() => removeAttachment(att.id)}
                  aria-label={`Remove ${att.name}`}
                >
                  <svg width="8" height="8" viewBox="0 0 8 8" fill="none">
                    <path d="M1 1l6 6M7 1l-6 6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" />
                  </svg>
                </button>
                <span class={styles.attachmentName}>{att.name}</span>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Main composer surface */}
      <div class={`${styles.surface} ${focused ? styles.surfaceFocused : ''} ${isWorking ? styles.surfaceWorking : ''} ${shellMode ? styles.surfaceShell : ''}`}>

        {/* Input area with completions */}
        <div class={styles.inputWrap}>
          <SkillCompletions
            ref={skillRef}
            skills={skills}
            value={value}
            cursorPos={cursorPos}
            onInsert={handleInsert}
          />
          <MentionCompletions
            ref={mentionRef}
            projectPath={projectPath}
            value={value}
            cursorPos={cursorPos}
            textareaRef={editorRef}
            onInsert={handleInsert}
          />
          <SlashCompletions
            ref={slashRef}
            value={value}
            cursorPos={cursorPos}
            onInsert={handleInsert}
            onAction={handleSlashAction}
            skills={skills}
          />

          {/* Contenteditable input */}
          <div
            ref={editorRef}
            class={styles.editor}
            contentEditable
            role="textbox"
            aria-multiline="true"
            aria-placeholder={shellMode ? 'Enter a shell command...' : isWorking ? 'Steer the agent...' : 'Send a message...'}
            data-placeholder={shellMode ? 'Enter a shell command...' : isWorking ? 'Steer the agent...' : 'Send a message...'}
            onInput={handleInput}
            onKeyDown={handleKeyDown}
            onPaste={handlePaste}
            onSelect={handleSelect}
            onClick={handleSelect}
            onFocus={() => setFocused(true)}
            onBlur={() => setFocused(false)}
            spellcheck={false}
          />
        </div>

        {/* Toolbar */}
        <div class={styles.toolbar}>
          <div class={styles.toolbarLeft}>
            {isWorking && onInterrupt && (
              <button
                type="button"
                class={`${styles.ghostAction} ${styles.ghostActionDanger}`}
                onClick={onInterrupt}
                aria-label="Stop agent"
                title="Stop"
              >
                <StopIcon />
              </button>
            )}
            {/* Model/effort control */}
            <div class={styles.workflowAnchor} ref={modelRef}>
              <button
                type="button"
                class={`${styles.ghostAction} ${modelPopoverOpen ? styles.ghostActionActive : ''}`}
                onClick={() => setModelPopoverOpen((v) => !v)}
                aria-label="Model & settings"
                title={session?.model ? shortModelName(session.model) : 'Model & settings'}
              >
                <TuneIcon />
              </button>
              <ModelEffortPopover
                open={modelPopoverOpen}
                onClose={() => setModelPopoverOpen(false)}
                provider={provider}
                models={availableModels}
                currentModel={session?.model}
                onModelChange={(model) => onModelChange?.(model)}
                effort={effort}
                onEffortChange={setEffort}
              />
            </div>
            <button
              type="button"
              class={styles.ghostAction}
              disabled={disabled}
              onClick={() => fileInputRef.current?.click()}
              aria-label="Attach image"
              title={`Attach image (${attachments.length}/${MAX_IMAGES})`}
            >
              <ImageIcon />
              {attachments.length > 0 && (
                <span class={styles.ghostBadge}>{attachments.length}</span>
              )}
            </button>
            <button
              type="button"
              class={styles.ghostAction}
              disabled={disabled}
              onClick={() => {
                const el = editorRef.current
                if (el) {
                  el.focus()
                  insertTextAtCursor('@')
                  syncFromDom()
                }
              }}
              aria-label="Mention file"
              title="Mention file (@)"
            >
              <MentionIcon />
            </button>
            <button
              type="button"
              class={styles.ghostAction}
              disabled={disabled}
              onClick={() => {
                const el = editorRef.current
                if (el) {
                  el.focus()
                  if (!value.trim()) {
                    insertTextAtCursor('/')
                    syncFromDom()
                  }
                }
              }}
              aria-label="Commands"
              title="Commands (/)"
            >
              <CommandIcon />
            </button>
            <div class={styles.toolbarSep} />
            {/* Workflow overflow */}
            <div class={styles.workflowAnchor} ref={workflowRef}>
              <button
                type="button"
                class={styles.ghostAction}
                onClick={() => setWorkflowOpen((v) => !v)}
                aria-label="More actions"
                title="More actions"
              >
                <MoreIcon />
              </button>
              <WorkflowMenu
                open={workflowOpen}
                onClose={() => setWorkflowOpen(false)}
                onUndo={onUndo}
                onFork={() => onFork()}
                onForkToWorktree={onForkToWorktree}
                onContinueInNew={onContinueInNew}
                onCompact={onCompact}
                isActive={isActive}
                shellMode={shellMode}
                onToggleShell={onShellExec ? () => setShellMode((v) => !v) : null}
              />
            </div>
          </div>

          <div class={styles.toolbarRight}>
            {/* Follow / pin controls */}
            {isPinned === false && unreadCount > 0 && (
              <button
                type="button"
                class={styles.unreadBadge}
                onClick={onScrollToBottom}
                aria-label={`${unreadCount} new messages`}
              >
                {unreadCount > 99 ? '99+' : unreadCount}
              </button>
            )}
            {isPinned !== undefined && (
              <button
                type="button"
                class={`${styles.followBtn} ${!isPinned ? styles.followBtnActive : ''}`}
                onClick={onScrollToBottom}
                aria-label={isPinned ? 'Following' : 'Scroll to bottom'}
                title={isPinned ? 'Following' : 'Scroll to bottom'}
              >
                {isPinned ? <PinIcon /> : <PauseIcon />}
              </button>
            )}

            {isPending && <span class={styles.pendingDot} aria-label="Sending..." />}
            <button
              type="submit"
              class={`${styles.sendBtn} ${canSend ? styles.sendBtnActive : ''} ${isSteering ? styles.sendBtnSteer : ''}`}
              disabled={!canSend}
              aria-label={isSteering ? 'Steer agent' : 'Send message'}
              title={isSteering ? 'Steer' : 'Send'}
            >
              {isSteering ? <SteerIcon /> : <SendIcon />}
            </button>
          </div>
        </div>

        {/* Status bar */}
        {showStatusBar && (
          <>
            <div class={styles.statusBarDivider} />
            <div class={styles.statusBar}>
              {isConnected === false && (
                <span class={`${styles.statusItem} ${styles.statusPill} ${styles.statusPillDisconnected}`}>
                  <span class={styles.statusDotRed} />
                  Disconnected
                </span>
              )}
              {provider === 'claude' && approvalPolicy && (
                <button
                  type="button"
                  class={`${styles.statusItem} ${styles.statusPill} ${styles.statusPillClickable}`}
                  onClick={onApprovalPolicyChange ? () => {
                    const policies = ['ask', 'auto-edit', 'auto-full']
                    const idx = policies.indexOf(approvalPolicy)
                    onApprovalPolicyChange(policies[(idx + 1) % policies.length])
                  } : undefined}
                  title="Click to cycle permission mode"
                >
                  {approvalPolicy === 'ask' ? 'Ask' : approvalPolicy === 'auto-edit' ? 'Auto-Edit' : 'Auto-Full'}
                </button>
              )}
              {tokenInfo && (
                <span class={`${styles.statusItem} ${styles.statusMono} ${tokenColorClass(tokenInfo.pct)}`}>
                  {tokenInfo.pct != null ? `${tokenInfo.pct}%` : ''}{tokenInfo.pct != null && tokenInfo.display ? ' · ' : ''}{tokenInfo.display}
                </span>
              )}
              {model && (
                <span class={`${styles.statusItem} ${styles.statusMono} ${styles.statusDimmed}`}>
                  {model}
                </span>
              )}
              {branch && (
                <span class={`${styles.statusItem} ${styles.statusBranch}`} title={branch}>
                  <GitBranchIcon />
                  <span class={styles.statusBranchText}>{branch}</span>
                </span>
              )}
              {cwdLabel && (
                <span class={`${styles.statusItem} ${styles.statusDimmed}`} title={cwd}>
                  <FolderIcon />
                  <span class={styles.statusMono}>{cwdLabel}</span>
                </span>
              )}
            </div>
          </>
        )}
      </div>

      {/* Drop target overlay */}
      {dragOver && (
        <div class={styles.dropOverlay}>
          <span class={styles.dropLabel}>Drop images to attach</span>
        </div>
      )}

      <input
        ref={fileInputRef}
        type="file"
        accept="image/*"
        multiple
        style="display:none"
        onChange={handleFileInput}
      />
    </form>
  )
}

export { MessageComposer }
