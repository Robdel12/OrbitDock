import { useState, useRef, useEffect, useCallback } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import { ProviderControls } from './provider-controls.jsx'
import { MentionCompletions } from './mention-completions.jsx'
import { SlashCompletions } from './slash-completions.jsx'
import { SkillCompletions } from './skill-completions.jsx'
import { addToast } from '../../stores/toasts.js'
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

// ── MessageComposer ──────────────────────────────────────────────────────────

const MessageComposer = ({
  sessionId,
  onSend,
  onSteer,
  onInterrupt,
  onResume,
  disabled,
  isWorking,
  isPending,
  isEnded,
  provider,
  approvalPolicy,
  onApprovalPolicyChange,
  projectPath,
  skills,
}) => {
  const [value, setValue] = useState('')
  const [attachments, setAttachments] = useState([])
  const [dragOver, setDragOver] = useState(false)
  const [effort, setEffort] = useState('medium')
  const [cursorPos, setCursorPos] = useState(0)
  const [focused, setFocused] = useState(false)
  const editorRef = useRef(null)
  const fileInputRef = useRef(null)
  const mentionRef = useRef(null)
  const slashRef = useRef(null)
  const skillRef = useRef(null)
  // Guard against recursive sync between state and DOM.
  const suppressSync = useRef(false)

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

  // ── Ended state ────────────────────────────────────────────────────────────

  if (isEnded) {
    return (
      <div class={styles.resumeBar}>
        <span class={styles.resumeLabel}>This session has ended.</span>
        <Button variant="primary" size="sm" type="button" onClick={onResume}>
          Resume Session
        </Button>
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
      <div class={`${styles.surface} ${focused ? styles.surfaceFocused : ''} ${isWorking ? styles.surfaceWorking : ''}`}>
        {/* Provider controls inside the surface */}
        {provider && (
          <div class={styles.surfaceControls}>
            <ProviderControls
              provider={provider}
              effort={effort}
              onEffortChange={setEffort}
              approvalPolicy={approvalPolicy}
              onApprovalPolicyChange={onApprovalPolicyChange}
            />
          </div>
        )}

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
            skills={skills}
          />

          {/* Contenteditable input */}
          <div
            ref={editorRef}
            class={styles.editor}
            contentEditable
            role="textbox"
            aria-multiline="true"
            aria-placeholder={isWorking ? 'Steer the agent...' : 'Send a message...'}
            data-placeholder={isWorking ? 'Steer the agent...' : 'Send a message...'}
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
                <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                  <rect x="1.5" y="1.5" width="9" height="9" rx="1.5" fill="currentColor" />
                </svg>
              </button>
            )}
            <button
              type="button"
              class={styles.ghostAction}
              disabled={disabled}
              onClick={() => fileInputRef.current?.click()}
              aria-label="Attach image"
              title={`Attach image (${attachments.length}/${MAX_IMAGES})`}
            >
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <rect x="1" y="3" width="12" height="9" rx="1.5" stroke="currentColor" stroke-width="1.2" />
                <circle cx="4.5" cy="6.5" r="1" fill="currentColor" />
                <path d="M1.5 10l3-3 2 2 2.5-3L13 10.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
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
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <path d="M2 4.5V3a1 1 0 011-1h8a1 1 0 011 1v8a1 1 0 01-1 1H3a1 1 0 01-1-1V9.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
                <path d="M5 7h4M7 5v4" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" />
              </svg>
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
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <path d="M9.5 2.5l-5 9" stroke="currentColor" stroke-width="1.3" stroke-linecap="round" />
                <circle cx="7" cy="7" r="5.5" stroke="currentColor" stroke-width="1.2" />
              </svg>
            </button>
            <div class={styles.toolbarSep} />
          </div>

          <div class={styles.toolbarRight}>
            {isPending && <span class={styles.pendingDot} aria-label="Sending..." />}
            <button
              type="submit"
              class={`${styles.sendBtn} ${canSend ? styles.sendBtnActive : ''}`}
              disabled={!canSend}
              aria-label={isWorking ? 'Steer agent' : 'Send message'}
              title={isWorking ? 'Steer' : 'Send'}
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path d="M6 10V2M6 2L2.5 5.5M6 2l3.5 3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" />
              </svg>
            </button>
          </div>
        </div>
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
