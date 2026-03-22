import { formatRelativeTime } from '../../lib/format.js'
import { extractRepoName } from '../../lib/group-sessions.js'
import { StatusDot } from '../ui/status-dot.jsx'
import styles from './session-card.module.css'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const ACTION_DESCRIPTIONS = {
  permission: 'Wants to run a tool',
  question: 'Has a question for you',
  working: 'Working',
  waiting: 'Waiting for input',
  reply: 'Ready for next message',
  ended: 'Session ended',
}

const getModelShortName = (model) => {
  if (!model) return null
  const lower = model.toLowerCase()
  if (lower.includes('opus')) return 'Opus'
  if (lower.includes('sonnet')) return 'Sonnet'
  if (lower.includes('haiku')) return 'Haiku'
  if (lower.includes('gpt-4')) return 'GPT-4'
  if (lower.includes('o1')) return 'o1'
  if (lower.includes('o3')) return 'o3'
  const parts = model.split('-')
  return parts[parts.length - 1]
}

const getDisplayName = (session) =>
  session.display_title ||
  session.custom_name ||
  session.summary ||
  session.first_prompt ||
  `Session ${session.id.slice(-8)}`

const getProjectName = (session) => extractRepoName(session.repository_root || session.project_path)

const getContext = (session) => {
  // context_line comes pre-computed from SessionListItem
  if (session.context_line) return session.context_line
  // For full SessionState objects, derive context from available fields
  const name = getDisplayName(session)
  if (session.summary && session.summary !== name) return session.summary
  if (session.first_prompt && session.first_prompt !== name) return session.first_prompt
  if (session.last_message) return session.last_message
  return null
}

// ---------------------------------------------------------------------------
// Model badge (tiny, monospaced)
// ---------------------------------------------------------------------------

const ModelBadge = ({ model }) => {
  const label = getModelShortName(model)
  if (!label) return null
  return <span class={styles.modelBadge}>{label}</span>
}

// ---------------------------------------------------------------------------
// Attention card — largest, tinted background, edge bar, action description
// ---------------------------------------------------------------------------

const AttentionCard = ({ session, onClick }) => {
  const displayName = getDisplayName(session)
  const actionDesc = ACTION_DESCRIPTIONS[session.work_status] || session.work_status
  const project = getProjectName(session)
  const context = getContext(session)

  return (
    <button
      class={`${styles.card} ${styles.cardAttention}`}
      onClick={onClick}
      style={{ '--card-status-color': `var(--color-status-${session.work_status})` }}
    >
      <div class={styles.edgeBar} />
      <div class={styles.cardContent}>
        {/* Action row: icon + description + model + chevron */}
        <div class={styles.actionRow}>
          <StatusDot status={session.work_status} />
          <span class={styles.actionLabel}>{actionDesc}</span>
          <span class={styles.cardSpacer} />
          <ModelBadge model={session.model} />
          {session.last_activity_at && (
            <span class={styles.recency}>{formatRelativeTime(session.last_activity_at)}</span>
          )}
          <span class={styles.actionChevron}>
            <svg
              width="14"
              height="14"
              viewBox="0 0 16 16"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M6 4l4 4-4 4" />
            </svg>
          </span>
        </div>

        {/* Identity row: name + project + branch */}
        <div class={styles.metaRow}>
          <span class={styles.sessionName}>{displayName}</span>
          {project && project !== 'Unknown' && (
            <>
              <span class={styles.metaDot}>&middot;</span>
              <span class={styles.metaText}>{project}</span>
            </>
          )}
          {session.branch && (
            <>
              <span class={styles.metaDot}>&middot;</span>
              <span class={styles.branchText}>{session.branch}</span>
            </>
          )}
        </div>

        {/* Context snippet */}
        {context && <p class={styles.contextAttention}>{context}</p>}
      </div>
    </button>
  )
}

// ---------------------------------------------------------------------------
// Working card — medium, cyan border + edge bar, current activity
// ---------------------------------------------------------------------------

const WorkingCard = ({ session, onClick }) => {
  const displayName = getDisplayName(session)
  const project = getProjectName(session)
  const context = getContext(session)

  return (
    <button class={`${styles.card} ${styles.cardWorking}`} onClick={onClick}>
      <div class={styles.edgeBar} />
      <div class={styles.cardContent}>
        {/* Name row */}
        <div class={styles.nameRow}>
          <StatusDot status="working" size="small" />
          <span class={styles.sessionNameWorking}>{displayName}</span>
          <span class={styles.cardSpacer} />
          <ModelBadge model={session.model} />
          {session.last_activity_at && (
            <span class={styles.recency}>{formatRelativeTime(session.last_activity_at)}</span>
          )}
        </div>

        {/* Project + branch metadata */}
        <div class={styles.metaRow}>
          {project && project !== 'Unknown' && <span class={styles.metaText}>{project}</span>}
          {session.branch && (
            <>
              {project && project !== 'Unknown' && <span class={styles.metaDot}>&middot;</span>}
              <span class={styles.branchText}>{session.branch}</span>
            </>
          )}
        </div>

        {/* Context snippet (1 line) */}
        {context && <p class={styles.contextWorking}>{context}</p>}
      </div>
    </button>
  )
}

// ---------------------------------------------------------------------------
// Ready card — compact two-line row, no edge bar
// ---------------------------------------------------------------------------

const ReadyCard = ({ session, onClick }) => {
  const displayName = getDisplayName(session)
  const project = getProjectName(session)
  const context = getContext(session)

  return (
    <button class={`${styles.card} ${styles.cardReady}`} onClick={onClick}>
      <div class={styles.readyContent}>
        {/* Line 1: dot + name + metadata + model + recency */}
        <div class={styles.readyLine1}>
          <StatusDot status={session.work_status} size="small" />
          <span class={styles.sessionNameReady}>{displayName}</span>
          {project && project !== 'Unknown' && (
            <>
              <span class={styles.metaDot}>&middot;</span>
              <span class={styles.metaText}>{project}</span>
            </>
          )}
          {session.branch && (
            <>
              <span class={styles.metaDot}>&middot;</span>
              <span class={styles.branchText}>{session.branch}</span>
            </>
          )}
          <span class={styles.cardSpacer} />
          <ModelBadge model={session.model} />
          {session.last_activity_at && (
            <span class={styles.recency}>{formatRelativeTime(session.last_activity_at)}</span>
          )}
        </div>

        {/* Line 2: context snippet */}
        {context && <p class={styles.contextReady}>{context}</p>}
      </div>
    </button>
  )
}

// ---------------------------------------------------------------------------
// SessionCard dispatcher — renders the right variant based on zone
// ---------------------------------------------------------------------------

const SessionCard = ({ session, variant = 'ready', onClick }) => {
  if (variant === 'attention') {
    return <AttentionCard session={session} onClick={onClick} />
  }
  if (variant === 'working') {
    return <WorkingCard session={session} onClick={onClick} />
  }
  return <ReadyCard session={session} onClick={onClick} />
}

export { SessionCard }
