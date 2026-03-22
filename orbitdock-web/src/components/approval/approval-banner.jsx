import { useEffect, useRef, useState } from 'preact/hooks'
import { extractDiffText, parseDiff } from '../../lib/parse-diff.js'
import { DiffView } from '../conversation/diff-view.jsx'
import { Button } from '../ui/button.jsx'
import { Card } from '../ui/card.jsx'
import styles from './approval-banner.module.css'

// ── Exec ─────────────────────────────────────────────────────────────────────

const ExecContent = ({ request, onDecide }) => {
  const toolName = request.tool_name || null
  const hasAmendment = request.proposed_amendment?.length > 0

  return (
    <div class={styles.body}>
      <div class={styles.headerRow}>
        <p class={styles.title}>{toolName || 'Tool'} wants to run a command</p>
        <span class={styles.badge}>APPROVAL</span>
      </div>
      {request.command && (
        <div class={styles.execMeta}>
          <pre class={styles.preview}>{request.command}</pre>
          {request.cwd && (
            <p class={styles.cwd}>
              <em class={styles.cwdLabel}>cwd</em>
              {request.cwd}
            </p>
          )}
        </div>
      )}
      {!request.command && request.preview && <pre class={styles.preview}>{request.preview.value}</pre>}
      {request.network_host && (
        <p class={styles.networkHint}>
          Network: {request.network_host}
          {request.network_protocol ? ` (${request.network_protocol})` : ''}
        </p>
      )}
      <div class={styles.actions}>
        <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
          Allow
        </Button>
        {hasAmendment && (
          <Button variant="secondary" size="sm" onClick={() => onDecide('approved_always')}>
            Always Allow
          </Button>
        )}
        <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
          Deny
        </Button>
      </div>
    </div>
  )
}

// ── Patch ─────────────────────────────────────────────────────────────────────

const PatchContent = ({ request, onDecide }) => {
  const diffText = extractDiffText(request)
  const diffLines = diffText ? parseDiff(diffText) : null
  const toolName = request.tool_name || null

  return (
    <div class={styles.body}>
      <div class={styles.headerRow}>
        <p class={styles.title}>{toolName || 'Tool'} wants to edit a file</p>
        <span class={styles.badge}>APPROVAL</span>
      </div>
      {request.file_path && <p class={styles.subtitle}>{request.file_path}</p>}
      {diffLines && diffLines.length > 0 && (
        <div class={styles.diffWrap}>
          <DiffView lines={diffLines} />
        </div>
      )}
      <div class={styles.actions}>
        <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
          Allow
        </Button>
        <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
          Deny
        </Button>
      </div>
    </div>
  )
}

// ── Permissions ───────────────────────────────────────────────────────────────

const PermissionsContent = ({ request, onDecide, onRespondPermission }) => {
  const [scope, setScope] = useState('turn')
  const perms = request.requested_permissions

  const handleGrant = () => {
    if (onRespondPermission) {
      onRespondPermission({ granted: true, scope })
    } else {
      onDecide('approved')
    }
  }

  const handleDeny = () => {
    if (onRespondPermission) {
      onRespondPermission({ granted: false, scope })
    } else {
      onDecide('denied')
    }
  }

  return (
    <div class={styles.body}>
      <div class={styles.headerRow}>
        <p class={styles.title}>Permissions Request</p>
        <span class={`${styles.badge} ${styles.badgePermission}`}>PERMISSIONS</span>
      </div>
      {request.permission_reason && <p class={styles.subtitle}>{request.permission_reason}</p>}
      {perms && perms.length > 0 && (
        <div class={styles.permList}>
          {perms.map((perm, i) => (
            <div key={i} class={styles.permItem}>
              {perm.type && <span class={styles.permType}>{perm.type}</span>}
              {perm.description && <span class={styles.permDescription}>{perm.description}</span>}
              {perm.scope && <span class={styles.permScope}>{perm.scope}</span>}
            </div>
          ))}
        </div>
      )}
      <div class={styles.scopeRow}>
        <span class={styles.scopeLabel}>Grant scope</span>
        <div class={styles.scopePicker}>
          <button
            class={`${styles.scopeOption} ${scope === 'turn' ? styles.scopeActive : ''}`}
            onClick={() => setScope('turn')}
            type="button"
          >
            This turn
          </button>
          <button
            class={`${styles.scopeOption} ${scope === 'session' ? styles.scopeActive : ''}`}
            onClick={() => setScope('session')}
            type="button"
          >
            Session
          </button>
        </div>
      </div>
      <div class={styles.actions}>
        <Button variant="primary" size="sm" onClick={handleGrant}>
          Grant
        </Button>
        <Button variant="danger" size="sm" onClick={handleDeny}>
          Deny
        </Button>
      </div>
    </div>
  )
}

// ── Question ──────────────────────────────────────────────────────────────────

const QuestionContent = ({ request, onAnswer, onDismiss }) => {
  const prompts = request.question_prompts || []
  const [activeIndex, setActiveIndex] = useState(0)
  const [answers, setAnswers] = useState({}) // { promptId: [selectedLabels] }
  const [drafts, setDrafts] = useState({}) // { promptId: freeTextValue }
  const otherRef = useRef(null)

  // Reset state when request changes.
  useEffect(() => {
    setActiveIndex(0)
    setAnswers({})
    setDrafts({})
  }, [request.id])

  const toggleOption = (promptId, label, allowsMultiple) => {
    setAnswers((prev) => {
      const existing = prev[promptId] || []
      let next
      if (allowsMultiple) {
        next = existing.includes(label) ? existing.filter((v) => v !== label) : [...existing, label]
      } else {
        next = [label]
      }
      return { ...prev, [promptId]: next.length ? next : undefined }
    })
  }

  const promptIsAnswered = (prompt) => {
    const selected = answers[prompt.id]
    const draft = (drafts[prompt.id] || '').trim()
    return (selected && selected.length > 0) || draft.length > 0
  }

  const allAnswered = () => {
    if (prompts.length === 0) return (drafts.default || '').trim().length > 0
    return prompts.every(promptIsAnswered)
  }

  const collectAnswers = () => {
    const collected = {}
    for (const prompt of prompts) {
      const values = [...(answers[prompt.id] || [])]
      const draft = (drafts[prompt.id] || '').trim()
      if (draft && !values.includes(draft)) values.push(draft)
      if (values.length) collected[prompt.id] = values
    }
    return collected
  }

  const handleSubmit = () => {
    if (prompts.length === 0) {
      // Simple question — just send the free-text answer.
      const text = (drafts.default || '').trim()
      if (text) onAnswer({ answer: text })
      return
    }

    const collected = collectAnswers()
    if (Object.keys(collected).length === 0) return

    // Derive primary answer: first selected value of first prompt.
    const primaryId = prompts[0].id
    const primaryValues = collected[primaryId] || Object.values(collected)[0] || []
    const primaryAnswer = primaryValues[0] || ''

    onAnswer({
      answer: primaryAnswer,
      question_id: primaryId,
      answers: collected,
    })
  }

  // No structured prompts — simple free-text question.
  if (prompts.length === 0) {
    return (
      <div class={styles.body}>
        <div class={styles.headerRow}>
          <p class={styles.title}>{request.question || 'Agent has a question'}</p>
          <span class={`${styles.badge} ${styles.badgeQuestion}`}>QUESTION</span>
        </div>
        <div class={styles.questionGroup}>
          <input
            class={styles.otherInput}
            type="text"
            placeholder="Your response..."
            value={drafts.default || ''}
            onInput={(e) => setDrafts((prev) => ({ ...prev, default: e.target.value }))}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                handleSubmit()
              }
            }}
          />
        </div>
        <div class={styles.actions}>
          {onDismiss && (
            <Button variant="secondary" size="sm" onClick={onDismiss}>
              Dismiss
            </Button>
          )}
          <Button variant="primary" size="sm" disabled={!(drafts.default || '').trim()} onClick={handleSubmit}>
            Submit
          </Button>
        </div>
      </div>
    )
  }

  // Multi-prompt question flow.
  const boundedIndex = Math.min(activeIndex, prompts.length - 1)
  const prompt = prompts[boundedIndex]
  const isLast = boundedIndex === prompts.length - 1
  const isFirst = boundedIndex === 0

  return (
    <div class={styles.body}>
      <div class={styles.headerRow}>
        <p class={styles.title}>{request.question || 'Agent has a question'}</p>
        <span class={`${styles.badge} ${styles.badgeQuestion}`}>QUESTION</span>
      </div>

      {/* Prompt tabs when there are multiple */}
      {prompts.length > 1 && (
        <div class={styles.promptTabs}>
          {prompts.map((p, i) => (
            <button
              key={p.id}
              class={`${styles.promptTab} ${i === boundedIndex ? styles.promptTabActive : ''} ${promptIsAnswered(p) ? styles.promptTabAnswered : ''}`}
              onClick={() => setActiveIndex(i)}
              type="button"
            >
              {p.header || `Q${i + 1}`}
            </button>
          ))}
        </div>
      )}

      {/* Current prompt */}
      <div class={styles.questionGroup}>
        <p class={styles.questionText}>{prompt.question}</p>
        {prompt.options?.length > 0 && (
          <div class={styles.options}>
            {prompt.options.map((opt) => {
              const selected = (answers[prompt.id] || []).includes(opt.label)
              return (
                <button
                  key={opt.label}
                  class={`${styles.optionBtn} ${selected ? styles.optionSelected : ''}`}
                  onClick={() => toggleOption(prompt.id, opt.label, prompt.allows_multiple_selection)}
                  type="button"
                >
                  {prompt.allows_multiple_selection && (
                    <span class={styles.checkbox}>{selected ? '\u2611' : '\u2610'}</span>
                  )}
                  <span class={styles.optionLabel}>{opt.label}</span>
                  {opt.description && <span class={styles.optionDesc}>{opt.description}</span>}
                </button>
              )
            })}
          </div>
        )}
        {prompt.allows_other && (
          <input
            ref={otherRef}
            class={styles.otherInput}
            type={prompt.is_secret ? 'password' : 'text'}
            placeholder="Other..."
            value={drafts[prompt.id] || ''}
            onInput={(e) => setDrafts((prev) => ({ ...prev, [prompt.id]: e.target.value }))}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                if (isLast && allAnswered()) handleSubmit()
                else if (!isLast) setActiveIndex(boundedIndex + 1)
              }
            }}
          />
        )}
      </div>

      {/* Navigation + submit */}
      <div class={styles.actions}>
        {onDismiss && (
          <Button variant="secondary" size="sm" onClick={onDismiss}>
            Dismiss
          </Button>
        )}
        {!isFirst && prompts.length > 1 && (
          <Button variant="secondary" size="sm" onClick={() => setActiveIndex(boundedIndex - 1)}>
            Back
          </Button>
        )}
        {!isLast && prompts.length > 1 && (
          <Button
            variant="secondary"
            size="sm"
            disabled={!promptIsAnswered(prompt)}
            onClick={() => setActiveIndex(boundedIndex + 1)}
          >
            Next
          </Button>
        )}
        {isLast && (
          <Button variant="primary" size="sm" disabled={!allAnswered()} onClick={handleSubmit}>
            Submit
          </Button>
        )}
      </div>
    </div>
  )
}

// ── MCP Elicitation ──────────────────────────────────────────────────────────

const ElicitationContent = ({ request, onAnswer, onDismiss }) => {
  const [code, setCode] = useState('')
  const serverName = request.mcp_server_name || 'MCP Server'
  const message = request.elicitation_message || request.question
  const isUrl = request.elicitation_mode === 'url'
  const url = request.elicitation_url

  const handleSubmit = () => {
    const trimmed = code.trim()
    if (!trimmed) return
    onAnswer({ answer: trimmed })
  }

  // URL auth flow — show link + code input
  if (isUrl) {
    return (
      <div class={styles.body}>
        <div class={styles.headerRow}>
          <p class={styles.title}>
            <span class={styles.mcpIcon}>
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                stroke-linecap="round"
                stroke-linejoin="round"
              >
                <rect x="2" y="2" width="20" height="8" rx="2" />
                <rect x="2" y="14" width="20" height="8" rx="2" />
                <circle cx="6" cy="6" r="1" />
                <circle cx="6" cy="18" r="1" />
              </svg>
            </span>
            {serverName}
          </p>
          <span class={`${styles.badge} ${styles.badgeMcp}`}>MCP AUTH</span>
        </div>
        {message && <p class={styles.questionText}>{message}</p>}
        {url && (
          <a class={styles.authLink} href={url} target="_blank" rel="noopener noreferrer">
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6" />
              <polyline points="15 3 21 3 21 9" />
              <line x1="10" y1="14" x2="21" y2="3" />
            </svg>
            Open in browser to authenticate
          </a>
        )}
        <div class={styles.questionGroup}>
          <input
            class={styles.otherInput}
            type="text"
            placeholder="Paste authorization code..."
            value={code}
            onInput={(e) => setCode(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.shiftKey) {
                e.preventDefault()
                handleSubmit()
              }
            }}
            autoFocus
          />
        </div>
        <div class={styles.actions}>
          {onDismiss && (
            <Button variant="secondary" size="sm" onClick={onDismiss}>
              Dismiss
            </Button>
          )}
          <Button variant="primary" size="sm" disabled={!code.trim()} onClick={handleSubmit}>
            Submit Code
          </Button>
        </div>
      </div>
    )
  }

  // Form mode — show MCP header then delegate to QuestionContent
  return (
    <div class={styles.body}>
      <div class={styles.headerRow}>
        <p class={styles.title}>
          <span class={styles.mcpIcon}>
            <svg
              width="14"
              height="14"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <rect x="2" y="2" width="20" height="8" rx="2" />
              <rect x="2" y="14" width="20" height="8" rx="2" />
              <circle cx="6" cy="6" r="1" />
              <circle cx="6" cy="18" r="1" />
            </svg>
          </span>
          {serverName}
        </p>
        <span class={`${styles.badge} ${styles.badgeMcp}`}>MCP</span>
      </div>
      {message && <p class={styles.questionText}>{message}</p>}
      <QuestionContent request={request} onAnswer={onAnswer} onDismiss={onDismiss} />
    </div>
  )
}

// ── Default ───────────────────────────────────────────────────────────────────

const DefaultContent = ({ request, onDecide }) => (
  <div class={styles.body}>
    <div class={styles.headerRow}>
      <p class={styles.title}>{request.tool_name || 'Approval needed'}</p>
      <span class={styles.badge}>APPROVAL</span>
    </div>
    {request.preview && <pre class={styles.preview}>{request.preview.value}</pre>}
    <div class={styles.actions}>
      <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
        Allow
      </Button>
      <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
        Deny
      </Button>
    </div>
  </div>
)

// ── ApprovalBanner ────────────────────────────────────────────────────────────

const ApprovalBanner = ({ request, onDecide, onAnswer, onDismiss, onRespondPermission }) => {
  if (!request) return null

  const isQuestion = request.type === 'question'
  const isMcpElicitation = isQuestion && request.elicitation_mode
  const edgeColor = isMcpElicitation ? 'accent' : isQuestion ? 'status-question' : 'status-permission'

  const renderContent = () => {
    switch (request.type) {
      case 'exec':
        return <ExecContent request={request} onDecide={onDecide} />
      case 'patch':
        return <PatchContent request={request} onDecide={onDecide} />
      case 'question':
        if (request.elicitation_mode) {
          return <ElicitationContent request={request} onAnswer={onAnswer} onDismiss={onDismiss} />
        }
        return <QuestionContent request={request} onAnswer={onAnswer} onDismiss={onDismiss} />
      case 'permissions':
        return <PermissionsContent request={request} onDecide={onDecide} onRespondPermission={onRespondPermission} />
      default:
        return <DefaultContent request={request} onDecide={onDecide} />
    }
  }

  return (
    <Card edgeColor={edgeColor} class={styles.banner}>
      {renderContent()}
    </Card>
  )
}

export { ApprovalBanner }
