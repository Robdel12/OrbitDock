import styles from './diff-available-banner.module.css'

/**
 * Banner shown when a `files_persisted` WS event fires.
 *
 * Props:
 *   onOpen()    — opens the review panel (clicking the banner body)
 *   onDismiss() — dismisses the banner without opening the panel
 */
const DiffAvailableBanner = ({ onOpen, onDismiss }) => (
  <div class={styles.banner} role="status" aria-live="polite">
    <span class={styles.dot} aria-hidden="true" />
    <button
      class={styles.bannerBody}
      onClick={onOpen}
      aria-label="Open code review panel"
    >
      <span class={styles.label}>Files changed</span>
      <span class={styles.hint}>— click to review diff</span>
    </button>
    <button
      class={styles.dismiss}
      onClick={onDismiss}
      aria-label="Dismiss"
      title="Dismiss"
    >
      <svg width="10" height="10" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2 2l8 8M10 2l-8 8"/></svg>
    </button>
  </div>
)

export { DiffAvailableBanner }
