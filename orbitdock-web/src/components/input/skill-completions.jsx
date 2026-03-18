import { useState, useEffect, useRef, useImperativeHandle } from 'preact/hooks'
import { forwardRef } from 'preact/compat'
import styles from './skill-completions.module.css'

// Returns the active skill query if the cursor is preceded by $word chars.
// Returns null otherwise.
const getActiveSkill = (text, cursorPos) => {
  const before = text.slice(0, cursorPos)
  const match = before.match(/\$(\w*)$/)
  if (!match) return null
  const start = cursorPos - match[0].length
  return {
    query: match[1],
    start,
    end: cursorPos,
  }
}

// Flatten all skill groups into a single array of enabled skills.
const flattenSkills = (groups) => {
  if (!groups) return []
  return groups.flatMap((group) =>
    (group.skills ?? []).filter((skill) => skill.enabled)
  )
}

const MAX_RESULTS = 8

const SkillCompletions = forwardRef(({ skills, value, cursorPos, onInsert }, ref) => {
  const [activeIndex, setActiveIndex] = useState(0)
  const listRef = useRef(null)

  const active = getActiveSkill(value, cursorPos)
  const allSkills = flattenSkills(skills)

  const filtered = active
    ? allSkills
        .filter((skill) => {
          const q = active.query.toLowerCase()
          return (
            skill.name.toLowerCase().includes(q) ||
            (skill.description ?? '').toLowerCase().includes(q)
          )
        })
        .slice(0, MAX_RESULTS)
    : []

  const open = filtered.length > 0

  // Reset active index whenever the filtered list changes.
  useEffect(() => {
    setActiveIndex(0)
  }, [active?.query])

  // Scroll active item into view.
  useEffect(() => {
    if (!listRef.current) return
    const el = listRef.current.children[activeIndex]
    el?.scrollIntoView({ block: 'nearest' })
  }, [activeIndex])

  const selectItem = (skill) => {
    if (!skill || !active) return
    onInsert(active.start, active.end, '$' + skill.name + ' ')
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
    <div class={styles.dropdown} role="listbox" aria-label="Skills" ref={listRef}>
      {filtered.map((skill, i) => (
        <button
          key={skill.name}
          class={`${styles.item} ${i === activeIndex ? styles.itemActive : ''}`}
          role="option"
          aria-selected={i === activeIndex}
          onMouseDown={(e) => {
            e.preventDefault()
            selectItem(skill)
          }}
          onMouseEnter={() => setActiveIndex(i)}
        >
          <span class={styles.skillName}>${skill.name}</span>
          <span class={styles.skillDesc}>
            {skill.short_description || skill.description || ''}
          </span>
        </button>
      ))}
    </div>
  )
})

export { SkillCompletions, getActiveSkill }
