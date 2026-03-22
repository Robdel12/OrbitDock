import { useEffect, useRef } from 'preact/hooks'
import styles from './action-popover.module.css'

/**
 * A lightweight inline popover panel anchored below a trigger button.
 * Closes on outside click or Escape. Rendered inline so it doesn't fight
 * with the header's flex layout — the caller controls the trigger + panel pair.
 *
 * Props:
 *   open        — boolean
 *   onClose     — () => void
 *   title       — string, shown as a small label above the content
 *   children    — the form body
 */
const ActionPopover = ({ open, onClose, title, children }) => {
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
    <div class={styles.popover} ref={ref}>
      {title && <p class={styles.title}>{title}</p>}
      {children}
    </div>
  )
}

export { ActionPopover }
