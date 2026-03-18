import { useState, useEffect, useRef, useImperativeHandle } from 'preact/hooks'
import { forwardRef } from 'preact/compat'
import { http } from '../../stores/connection.js'
import styles from './mention-completions.module.css'

// Returns the active @mention query if the cursor is within one, otherwise null.
// `text` — full textarea value, `cursorPos` — current selectionStart
const getActiveMention = (text, cursorPos) => {
  const before = text.slice(0, cursorPos)
  const match = before.match(/@([\w./\-]*)$/)
  if (!match) return null
  return {
    query: match[1],
    start: cursorPos - match[0].length,
    end: cursorPos,
  }
}

// Simple fuzzy match — checks if all query chars appear in order in the target.
const fuzzyMatch = (query, target) => {
  if (!query) return true
  const q = query.toLowerCase()
  const t = target.toLowerCase()
  let qi = 0
  for (let ti = 0; ti < t.length && qi < q.length; ti++) {
    if (t[ti] === q[qi]) qi++
  }
  return qi === q.length
}

const MentionCompletions = forwardRef(({ projectPath, value, cursorPos, textareaRef, onInsert }, ref) => {
  const [suggestions, setSuggestions] = useState([])
  const [activeIndex, setActiveIndex] = useState(0)
  const [open, setOpen] = useState(false)
  const listRef = useRef(null)
  const abortRef = useRef(null)

  const mention = getActiveMention(value, cursorPos)

  // Fetch file listings from /api/fs/browse whenever the query changes.
  useEffect(() => {
    if (!mention) {
      setOpen(false)
      setSuggestions([])
      return
    }

    // Abort any in-flight fetch.
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller

    const fetchFiles = async () => {
      try {
        const query = mention.query
        const hasSlash = query.includes('/')
        let browsePath
        let filterQuery

        if (hasSlash) {
          // Query contains a path separator — browse the directory portion.
          const lastSlash = query.lastIndexOf('/')
          const dirPart = query.slice(0, lastSlash + 1)
          filterQuery = query.slice(lastSlash + 1)
          browsePath = projectPath ? `${projectPath}/${dirPart}` : dirPart
        } else {
          // Plain text query — browse the project root and filter.
          browsePath = projectPath || undefined
          filterQuery = query
        }

        const data = await http.get('/api/fs/browse', browsePath ? { path: browsePath } : undefined)
        if (controller.signal.aborted) return

        const entries = data?.entries || []
        // Filter by fuzzy match on the remaining query portion.
        const filtered = entries
          .filter((entry) => fuzzyMatch(filterQuery, entry.name))
          // Sort directories first, then alphabetically.
          .sort((a, b) => {
            if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1
            return a.name.localeCompare(b.name)
          })
          .slice(0, 20)
          // Build the full relative path for each entry.
          .map((entry) => {
            const prefix = hasSlash ? query.slice(0, query.lastIndexOf('/') + 1) : ''
            return {
              name: entry.name,
              path: prefix + entry.name + (entry.is_dir ? '/' : ''),
              isDir: entry.is_dir,
            }
          })

        setSuggestions(filtered)
        setActiveIndex(0)
        setOpen(filtered.length > 0)
      } catch (err) {
        if (err.name === 'AbortError') return
        setSuggestions([])
        setOpen(false)
      }
    }

    fetchFiles()
  }, [mention?.query, projectPath])

  // Scroll active item into view.
  useEffect(() => {
    if (!listRef.current) return
    const el = listRef.current.children[activeIndex]
    el?.scrollIntoView({ block: 'nearest' })
  }, [activeIndex])

  const selectItem = (item) => {
    if (!item || !mention) return
    if (item.isDir) {
      // Selecting a directory drills into it by updating the query.
      // Insert the path so far (which ends with /) and the dropdown stays open.
      onInsert(mention.start, mention.end, `@${item.path}`)
    } else {
      // Selecting a file completes the mention with a trailing space.
      onInsert(mention.start, mention.end, `@${item.path} `)
    }
    if (!item.isDir) {
      setOpen(false)
      setSuggestions([])
    }
  }

  // Keyboard navigation — callers must forward keydown events here.
  // Returns true if the event was handled so the composer can stop propagation.
  const handleKeyDown = (e) => {
    if (!open) return false

    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActiveIndex((i) => (i + 1) % suggestions.length)
      return true
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActiveIndex((i) => (i - 1 + suggestions.length) % suggestions.length)
      return true
    }
    if (e.key === 'Enter' || e.key === 'Tab') {
      e.preventDefault()
      selectItem(suggestions[activeIndex])
      return true
    }
    if (e.key === 'Escape') {
      setOpen(false)
      return true
    }
    return false
  }

  // Expose handleKeyDown imperatively so the parent composer can delegate to it.
  useImperativeHandle(ref, () => ({ handleKeyDown }))

  if (!open || suggestions.length === 0) return null

  // Position the dropdown above the textarea.
  return (
    <div class={styles.dropdown} role="listbox" aria-label="File suggestions" ref={listRef}>
      {suggestions.map((item, i) => (
        <button
          key={item.path}
          class={`${styles.item} ${i === activeIndex ? styles.itemActive : ''}`}
          role="option"
          aria-selected={i === activeIndex}
          onMouseDown={(e) => {
            // Prevent the textarea from losing focus.
            e.preventDefault()
            selectItem(item)
          }}
          onMouseEnter={() => setActiveIndex(i)}
        >
          <span class={styles.filename}>
            {item.isDir ? '\u{1F4C1}' : '\u{1F4C4}'}{' '}
            {item.name}
          </span>
          {item.isDir && <span class={styles.dir}>directory</span>}
        </button>
      ))}
    </div>
  )
})

export { MentionCompletions, getActiveMention }
