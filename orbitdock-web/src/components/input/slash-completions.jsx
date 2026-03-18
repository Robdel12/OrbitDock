import { useState, useEffect, useRef, useImperativeHandle, useMemo } from 'preact/hooks'
import { forwardRef } from 'preact/compat'
import styles from './slash-completions.module.css'

// Static list of slash commands available in the composer.
const SLASH_COMMANDS = [
  { name: '/help',         description: 'Show available commands and usage' },
  { name: '/compact',      description: 'Compact the conversation context' },
  { name: '/clear',        description: 'Clear the conversation history' },
  { name: '/model',        description: 'Switch the AI model' },
  { name: '/think',        description: 'Enable extended thinking mode' },
  { name: '/status',       description: 'Show current session status' },
  { name: '/cost',         description: 'Show token usage and cost estimate' },
  { name: '/reset',        description: 'Reset session context' },
  { name: '/resume',       description: 'Resume a paused or ended session' },
  { name: '/shell',        description: 'Run a shell command directly' },
]

// Returns the active slash query if the cursor is at the start of a line
// and the text begins with /. Returns null otherwise.
const getActiveSlash = (text, cursorPos) => {
  const before = text.slice(0, cursorPos)
  // Only trigger when / is at the start of a line (position 0 or after \n)
  const lastNewline = before.lastIndexOf('\n')
  const lineStart = lastNewline + 1
  const line = before.slice(lineStart)
  const match = line.match(/^(\/[\w]*)$/)
  if (!match) return null
  return {
    query: match[1],
    start: lineStart,
    end: cursorPos,
  }
}

const SlashCompletions = forwardRef(({ value, cursorPos, onInsert, skills }, ref) => {
  const [activeIndex, setActiveIndex] = useState(0)
  const listRef = useRef(null)

  const slash = getActiveSlash(value, cursorPos)

  const dynamicCommands = useMemo(() => {
    const cmds = [...SLASH_COMMANDS]
    if (skills) {
      const flatSkills = skills.flatMap((group) => group.skills || [])
      for (const skill of flatSkills) {
        if (skill.enabled !== false) {
          cmds.push({
            name: `/skill:${skill.name}`,
            description: skill.short_description || skill.description || '',
            isSkill: true,
          })
        }
      }
    }
    return cmds
  }, [skills])

  const filtered = slash
    ? dynamicCommands.filter((cmd) => cmd.name.toLowerCase().startsWith(slash.query.toLowerCase()))
    : []

  const open = filtered.length > 0

  // Reset active index whenever the filtered list changes.
  useEffect(() => {
    setActiveIndex(0)
  }, [slash?.query])

  // Scroll active item into view.
  useEffect(() => {
    if (!listRef.current) return
    const el = listRef.current.children[activeIndex]
    el?.scrollIntoView({ block: 'nearest' })
  }, [activeIndex])

  const selectItem = (cmd) => {
    if (!cmd || !slash) return
    onInsert(slash.start, slash.end, cmd.name + ' ')
  }

  // Keyboard navigation — returns true if the event was handled.
  const handleKeyDown = (e) => {
    if (!open) return false

    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActiveIndex((i) => (i + 1) % filtered.length)
      return true
    }
    if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActiveIndex((i) => (i - 1 + filtered.length) % filtered.length)
      return true
    }
    if (e.key === 'Enter' || e.key === 'Tab') {
      e.preventDefault()
      selectItem(filtered[activeIndex])
      return true
    }
    if (e.key === 'Escape') {
      return true
    }
    return false
  }

  // Expose handleKeyDown imperatively so the parent composer can delegate to it.
  useImperativeHandle(ref, () => ({ handleKeyDown }))

  if (!open) return null

  return (
    <div class={styles.dropdown} role="listbox" aria-label="Slash commands" ref={listRef}>
      {filtered.map((cmd, i) => (
        <button
          key={cmd.name}
          class={`${styles.item} ${i === activeIndex ? styles.itemActive : ''} ${cmd.isSkill ? styles.skillEntry : ''}`}
          role="option"
          aria-selected={i === activeIndex}
          onMouseDown={(e) => {
            e.preventDefault()
            selectItem(cmd)
          }}
          onMouseEnter={() => setActiveIndex(i)}
        >
          <span class={styles.cmdName}>{cmd.name}</span>
          <span class={styles.cmdDesc}>{cmd.description}</span>
        </button>
      ))}
    </div>
  )
})

export { SlashCompletions, getActiveSlash }
