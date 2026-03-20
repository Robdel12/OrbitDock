import { useEffect } from 'preact/hooks'
import styles from './keyboard-help.module.css'

const SHORTCUT_GROUPS = [
  {
    label: 'Global',
    shortcuts: [
      { keys: ['⌘', 'K'], description: 'Open command palette' },
      { keys: ['?'], description: 'Show keyboard shortcuts' },
      { keys: ['Esc'], description: 'Go back / close dialog' },
    ],
  },
  {
    label: 'Session',
    shortcuts: [
      { keys: ['E'], description: 'End session' },
      { keys: ['C'], description: 'Compact context' },
      { keys: ['I'], description: 'Interrupt agent' },
      { keys: ['R'], description: 'Resume session' },
    ],
  },
  {
    label: 'Navigation',
    shortcuts: [
      { keys: ['J'], description: 'Next session (dashboard)' },
      { keys: ['K'], description: 'Previous session (dashboard)' },
      { keys: ['↑', '↓'], description: 'Navigate list items' },
      { keys: ['↵'], description: 'Open selected session' },
    ],
  },
  {
    label: 'Review',
    shortcuts: [
      { keys: ['N'], description: 'Next diff hunk' },
      { keys: ['P'], description: 'Previous diff hunk' },
      { keys: ['C'], description: 'Comment on hunk' },
      { keys: ['A'], description: 'Approve change' },
      { keys: ['D'], description: 'Deny change' },
    ],
  },
]

const KeyChip = ({ children }) => (
  <kbd class={styles.key}>{children}</kbd>
)

const KeyboardHelp = ({ onClose }) => {
  useEffect(() => {
    const onKeyDown = (e) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        onClose()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [onClose])

  return (
    <div
      class={styles.overlay}
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label="Keyboard shortcuts"
    >
      <div class={styles.panel} onClick={(e) => e.stopPropagation()}>
        <div class={styles.header}>
          <h2 class={styles.title}>Keyboard Shortcuts</h2>
          <button class={styles.closeBtn} onClick={onClose} aria-label="Close">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2 2l8 8M10 2l-8 8"/></svg>
          </button>
        </div>

        <div class={styles.body}>
          {SHORTCUT_GROUPS.map((group) => (
            <div key={group.label} class={styles.group}>
              <div class={styles.groupLabel}>{group.label}</div>
              <div class={styles.shortcutList}>
                {group.shortcuts.map((shortcut, i) => (
                  <div key={i} class={styles.shortcutRow}>
                    <div class={styles.keys}>
                      {shortcut.keys.map((k, ki) => (
                        <KeyChip key={ki}>{k}</KeyChip>
                      ))}
                    </div>
                    <span class={styles.description}>{shortcut.description}</span>
                  </div>
                ))}
              </div>
            </div>
          ))}
        </div>

        <div class={styles.footer}>
          <kbd class={styles.key}>Esc</kbd>
          <span class={styles.footerHint}>to close</span>
        </div>
      </div>
    </div>
  )
}

export { KeyboardHelp }
