import { useEffect, useMemo, useState } from 'preact/hooks'
import { useRoute, useLocation } from 'wouter-preact'
import { createConversationStore } from '../stores/conversation.js'
import { selectSession, selected } from '../stores/sessions.js'
import { setConversationHandler } from '../stores/connection.js'
import { addToast } from '../stores/toasts.js'
import { useSession } from '../hooks/use-session.js'
import { useScrollAnchor } from '../hooks/use-scroll-anchor.js'
import { ConversationView } from '../components/conversation/conversation-view.jsx'
import { MessageComposer } from '../components/input/message-composer.jsx'
import { RateLimitBanner } from '../components/input/rate-limit-banner.jsx'
import { SessionHeader } from '../components/session/session-header.jsx'
import { WorkerRosterPanel } from '../components/session/worker-roster-panel.jsx'
import { SessionActionBar } from '../components/session/session-action-bar.jsx'
import { DiffAvailableBanner } from '../components/session/diff-available-banner.jsx'
import { WorktreeCleanupBanner } from '../components/session/worktree-cleanup-banner.jsx'
import { CapabilitiesPanel } from '../components/session/capabilities-panel.jsx'
import { SessionSkeleton } from '../components/session/session-skeleton.jsx'
import { ReviewPanel } from '../components/review/review-panel.jsx'
import { ApprovalBanner } from '../components/approval/approval-banner.jsx'
import { connectionState, http } from '../stores/connection.js'
import { useMachine } from '../hooks/use-machine.js'
import { useKeyboard } from '../hooks/use-keyboard.js'
import { approvalMachine } from '../machines/approval.machine.js'
import {
  reviewPanelOpen,
  openReviewPanel,
  closeReviewPanel,
  resetReview,
  handleReviewWsEvent,
} from '../stores/review.js'
import styles from './session.module.css'

const SessionPage = () => {
  const [, params] = useRoute('/session/:id')
  const [, navigate] = useLocation()
  const sessionId = params?.id

  const conversation = useMemo(() => createConversationStore(), [sessionId])
  const [approvalState, sendApproval] = useMachine(approvalMachine, {
    input: { sessionId },
  })

  // True until the first REST fetch for conversation data resolves.
  const [isBootstrapping, setIsBootstrapping] = useState(true)

  // Rate limit: null means no active limit; populated with info from the WS event.
  const [rateLimitInfo, setRateLimitInfo] = useState(null)

  // Pending: true between send and the first WS user row that confirms receipt.
  const [isPending, setIsPending] = useState(false)

  // Claude approval policy — initialised from session once it loads.
  const [approvalPolicy, setApprovalPolicy] = useState('ask')

  // Token usage from tokens_updated WS events.
  const [tokenUsage, setTokenUsage] = useState(null)

  // Diff available banner: shown when files_persisted arrives, dismissed manually.
  const [diffAvailable, setDiffAvailable] = useState(false)

  // Unread count: rows received while scrolled away from bottom.
  const [unreadCount, setUnreadCount] = useState(0)

  // Capabilities panel open state and live WS payloads for skills / MCP.
  const [capabilitiesOpen, setCapabilitiesOpen] = useState(false)
  const [liveSkills, setLiveSkills] = useState(null)
  const [liveMcpTools, setLiveMcpTools] = useState(null)

  // Review panel open state (read from store signal for rendering).
  const reviewOpen = reviewPanelOpen.value

  // Scroll anchor owned at page level so SessionActionBar can observe isPinned.
  const scrollAnchor = useScrollAnchor()

  useSession(sessionId)

  useKeyboard({
    // Priority: review panel > capabilities panel > navigate away.
    Escape: () => {
      if (reviewPanelOpen.value) {
        closeReviewPanel()
      } else if (capabilitiesOpen) {
        setCapabilitiesOpen(false)
      } else {
        navigate('/')
      }
    },
  })

  // Reset unread count when the user scrolls back to the bottom.
  useEffect(() => {
    const unsubscribe = scrollAnchor.isPinned.subscribe((pinned) => {
      if (pinned) setUnreadCount(0)
    })
    return unsubscribe
  }, [scrollAnchor.isPinned])

  useEffect(() => {
    if (!sessionId) return
    selectSession(sessionId)

    setIsBootstrapping(true)

    // Fetch initial conversation via REST (WS only delivers incremental updates)
    const fetchConversation = async () => {
      try {
        const data = await http.get(`/api/sessions/${sessionId}/conversation`)
        if (data.session) {
          conversation.applyBootstrap({
            rows: data.session.rows || [],
            total_row_count: data.session.total_row_count || 0,
            has_more_before: data.session.has_more_before || false,
            oldest_sequence: data.session.oldest_sequence ?? null,
            newest_sequence: data.session.newest_sequence ?? null,
          })
        }
      } catch (err) {
        console.warn('[session] failed to fetch conversation:', err.message)
      } finally {
        setIsBootstrapping(false)
      }
    }
    fetchConversation()

    // WS handler for live incremental updates
    const handler = (msg) => {
      if (msg.type === 'conversation_rows_changed' && msg.session_id === sessionId) {
        conversation.applyRowsChanged(msg)
        // Clear pending once a user row arrives confirming the message was received.
        const hasUserRow = msg.upserted?.some((e) => e.row?.row_type === 'user')
        if (hasUserRow) setIsPending(false)
        // Bump unread badge when new rows arrive while scrolled away from bottom.
        if (!scrollAnchor.isPinned.value && msg.upserted?.length > 0) {
          setUnreadCount((n) => n + msg.upserted.length)
        }
      } else if (msg.type === 'tokens_updated' && msg.session_id === sessionId) {
        if (msg.usage) setTokenUsage(msg.usage)
      } else if (msg.type === 'files_persisted' && msg.session_id === sessionId) {
        setDiffAvailable(true)
      } else if (msg.type === 'approval_requested' && msg.session_id === sessionId) {
        sendApproval({
          type: 'APPROVAL_REQUESTED',
          request: msg.request,
          approval_version: msg.approval_version,
        })
      } else if (msg.type === 'approval_decision_result' && msg.session_id === sessionId) {
        sendApproval({
          type: 'SUBMIT_SUCCESS',
          approval_version: msg.approval_version,
        })
      } else if (msg.type === 'rate_limit_event' && msg.session_id === sessionId) {
        setRateLimitInfo(msg.info ?? null)
      } else if (msg.type === 'skills_list' && msg.session_id === sessionId) {
        setLiveSkills(msg.skills ?? null)
      } else if (msg.type === 'mcp_tools_list' && msg.session_id === sessionId) {
        setLiveMcpTools(msg)
      } else if (
        msg.session_id === sessionId && (
          msg.type === 'review_comment_created' ||
          msg.type === 'review_comment_updated' ||
          msg.type === 'review_comment_deleted' ||
          msg.type === 'review_comments_list' ||
          msg.type === 'turn_diff_snapshot'
        )
      ) {
        handleReviewWsEvent(msg)
      }
    }

    setConversationHandler(handler)
    return () => {
      setConversationHandler(null)
      setRateLimitInfo(null)
      setIsPending(false)
      setTokenUsage(null)
      setDiffAvailable(false)
      setUnreadCount(0)
      setIsBootstrapping(true)
      setLiveSkills(null)
      setLiveMcpTools(null)
      resetReview()
    }
  }, [sessionId])

  // Seed the local approval policy from the session object whenever the
  // session loads or changes (e.g. navigating between sessions).
  useEffect(() => {
    const policy = selected.value?.approval_policy
    if (policy) setApprovalPolicy(policy)
  }, [sessionId, selected.value?.approval_policy])

  if (!sessionId) return null
  if (isBootstrapping) return <SessionSkeleton />

  const session = selected.value
  const rows = conversation.rows.value
  const approvalSnapshot = approvalState.value
  const pendingRequest =
    approvalSnapshot.value === 'pending' ? approvalSnapshot.context.request : null

  const handleSend = (payload) => {
    setIsPending(true)
    const body = { content: payload.content || '' }
    if (payload.images && payload.images.length) body.images = payload.images
    if (payload.effort) body.effort = payload.effort
    http.post(`/api/sessions/${sessionId}/messages`, body).catch((err) => {
      console.warn('[session] send failed:', err.message)
      addToast({ title: 'Send failed', body: err.message, type: 'error' })
      setIsPending(false)
    })
  }

  const handleApprovalPolicyChange = (policy) => {
    const previousPolicy = approvalPolicy
    setApprovalPolicy(policy)
    http.patch(`/api/sessions/${sessionId}/config`, { approval_policy: policy }).catch((err) => {
      console.warn('[session] approval policy update failed:', err.message)
      setApprovalPolicy(previousPolicy)
    })
  }

  const handleModelChange = (model) => {
    http.patch(`/api/sessions/${sessionId}/config`, { model }).catch((err) => {
      console.warn('[session] model change failed:', err.message)
      addToast({ title: 'Model change failed', body: err.message, type: 'error' })
    })
  }

  const handleDecide = (decision) => {
    if (!pendingRequest) return
    sendApproval({ type: 'DECIDE', decision })
    http.post(`/api/sessions/${sessionId}/approve`, {
      request_id: pendingRequest.id,
      decision,
    }).then(() => {
      // approval_decision_result comes via WS
    }).catch((err) => {
      sendApproval({ type: 'SUBMIT_ERROR', error: err.message })
    })
  }

  const handleAnswer = (payload) => {
    if (!pendingRequest) return
    sendApproval({ type: 'ANSWER' })
    http.post(`/api/sessions/${sessionId}/answer`, {
      request_id: pendingRequest.id,
      answer: payload.answer || '',
      ...(payload.question_id ? { question_id: payload.question_id } : {}),
      ...(payload.answers ? { answers: payload.answers } : {}),
    }).catch((err) => {
      sendApproval({ type: 'SUBMIT_ERROR', error: err.message })
    })
  }

  const handleDismiss = () => {
    if (!pendingRequest) return
    sendApproval({ type: 'DECIDE', decision: 'denied' })
    http.post(`/api/sessions/${sessionId}/approve`, {
      request_id: pendingRequest.id,
      decision: 'denied',
      message: 'Dismissed',
    }).catch((err) => {
      sendApproval({ type: 'SUBMIT_ERROR', error: err.message })
    })
  }

  const handleRespondPermission = ({ granted, scope }) => {
    if (!pendingRequest) return
    sendApproval({ type: 'GRANT_PERMISSION' })
    http.post(`/api/sessions/${sessionId}/permissions/respond`, {
      request_id: pendingRequest.id,
      permissions: granted ? pendingRequest.requested_permissions : null,
      ...(scope ? { scope } : {}),
    }).catch((err) => {
      sendApproval({ type: 'SUBMIT_ERROR', error: err.message })
    })
  }

  const isEnded = session?.status === 'ended' || session?.work_status === 'ended'
  const isWorking = session?.work_status === 'working'
  const isPassive = session?.work_status === 'reply' || session?.work_status === 'ended'
  const showTakeover = session?.status === 'active' && isPassive
  const showWorktreeBanner = isEnded && session?.is_worktree && !!session?.worktree_id

  const handleInterrupt = () => {
    http.post(`/api/sessions/${sessionId}/interrupt`)
  }

  const handleCompact = () => {
    http.post(`/api/sessions/${sessionId}/compact`)
  }

  const handleUndo = () => {
    http.post(`/api/sessions/${sessionId}/undo`)
  }

  const handleEnd = () => {
    http.post(`/api/sessions/${sessionId}/end`)
  }

  const handleRename = (name) => {
    http.patch(`/api/sessions/${sessionId}/name`, { name }).catch((err) => {
      console.warn('[session] rename failed:', err.message)
    })
    // The sidebar updates automatically via session_list_item_updated WS event
  }

  const handleFork = (nthUserMessage) => {
    const body = nthUserMessage != null ? { nth_user_message: nthUserMessage } : {}
    http.post(`/api/sessions/${sessionId}/fork`, body).then((res) => {
      if (res?.session?.id) navigate(`/session/${res.session.id}`)
    }).catch((err) => {
      console.warn('[session] fork failed:', err.message)
    })
  }

  const handleTakeover = () => {
    http.post(`/api/sessions/${sessionId}/takeover`).catch((err) => {
      console.warn('[session] takeover failed:', err.message)
    })
  }

  const handleRollback = (numTurns) => {
    http.post(`/api/sessions/${sessionId}/rollback`, { num_turns: numTurns }).catch((err) => {
      console.warn('[session] rollback failed:', err.message)
    })
  }

  const handleSteer = (content) => {
    http.post(`/api/sessions/${sessionId}/steer`, { content }).catch((err) => {
      console.warn('[session] steer failed:', err.message)
    })
  }

  const handleShellExec = (command) => {
    http.post(`/api/sessions/${sessionId}/shell/exec`, { command, timeout_secs: 120 }).catch((err) => {
      console.warn('[session] shell exec failed:', err.message)
      addToast({ title: 'Shell exec failed', body: err.message, type: 'error' })
    })
  }

  const handleResume = () => {
    http.post(`/api/sessions/${sessionId}/resume`).catch((err) => {
      console.warn('[session] resume failed:', err.message)
    })
  }

  const handleDeleteWorktree = (worktreeId) =>
    http.del(`/api/worktrees/${worktreeId}`).catch((err) => {
      console.warn('[session] worktree delete failed:', err.message)
    })

  const handleContinueInNew = () => {
    // Fork from the latest message into a new session
    http.post(`/api/sessions/${sessionId}/fork`).then((res) => {
      if (res?.session?.id) navigate(`/session/${res.session.id}`)
    }).catch((err) => {
      console.warn('[session] continue in new failed:', err.message)
      addToast({ title: 'Continue failed', body: err.message, type: 'error' })
    })
  }

  const handleForkToWorktree = () => {
    http.post(`/api/sessions/${sessionId}/fork-to-worktree`).then((res) => {
      if (res?.session?.id) navigate(`/session/${res.session.id}`)
    }).catch((err) => {
      console.warn('[session] fork to worktree failed:', err.message)
      addToast({ title: 'Fork to worktree failed', body: err.message, type: 'error' })
    })
  }

  const handleToggleCapabilities = () => setCapabilitiesOpen((v) => !v)

  const handleOpenReview = () => {
    setDiffAvailable(false)
    openReviewPanel(sessionId)
  }

  const handleCloseReview = () => closeReviewPanel()

  return (
    <div class={`${styles.page} ${reviewOpen ? styles.pageWithReview : ''}`}>
      {/* ── Left column: conversation ────────────────────────────────────── */}
      <div class={`${styles.conversationCol} ${reviewOpen ? styles.conversationColNarrow : ''}`}>
        <SessionHeader
          session={session}
          onEnd={handleEnd}
          onRename={handleRename}
          onFork={handleFork}
          onForkToWorktree={handleForkToWorktree}
          onContinueInNew={handleContinueInNew}
          onTakeover={handleTakeover}
          onRollback={handleRollback}
          onToggleCapabilities={handleToggleCapabilities}
          capabilitiesOpen={capabilitiesOpen}
          reviewOpen={reviewOpen}
          onReviewToggle={reviewOpen ? handleCloseReview : handleOpenReview}
          tokenUsage={tokenUsage}
        />
        <WorkerRosterPanel rows={rows} />
        {diffAvailable && (
          <DiffAvailableBanner
            onOpen={handleOpenReview}
            onDismiss={() => setDiffAvailable(false)}
          />
        )}
        <ConversationView
          rows={rows}
          isLoadingHistory={conversation.isLoadingHistory.value}
          hasMoreBefore={conversation.hasMoreBefore.value}
          onLoadOlder={() => conversation.loadOlder(http, sessionId)}
          scrollRef={scrollAnchor}
          session={session}
          unreadCount={unreadCount}
        />
        {rateLimitInfo && (
          <RateLimitBanner
            info={rateLimitInfo}
            onExpired={() => setRateLimitInfo(null)}
          />
        )}
        <SessionActionBar session={session} />
        {showWorktreeBanner && (
          <WorktreeCleanupBanner
            worktreeId={session.worktree_id}
            onDelete={handleDeleteWorktree}
          />
        )}
        {pendingRequest && (
          <ApprovalBanner
            request={pendingRequest}
            onDecide={handleDecide}
            onAnswer={handleAnswer}
            onDismiss={handleDismiss}
            onRespondPermission={handleRespondPermission}
          />
        )}
        {/* Takeover banner — visible when viewing a passive session */}
        {showTakeover && (
          <div class={styles.takeoverBanner}>
            <span class={styles.takeoverDot} />
            <span class={styles.takeoverLabel}>Take over to send messages</span>
            <button class={styles.takeoverBtn} onClick={handleTakeover}>
              Take Over
            </button>
          </div>
        )}
        <MessageComposer
          sessionId={sessionId}
          onSend={handleSend}
          onSteer={handleSteer}
          onShellExec={handleShellExec}
          onInterrupt={handleInterrupt}
          onResume={handleResume}
          onContinueInNew={handleContinueInNew}
          onUndo={handleUndo}
          onFork={handleFork}
          onForkToWorktree={handleForkToWorktree}
          onCompact={handleCompact}
          onEnd={handleEnd}
          disabled={isEnded}
          isWorking={isWorking}
          isPending={isPending}
          isEnded={isEnded}
          isConnected={connectionState.value === 'connected'}
          provider={session?.provider}
          approvalPolicy={approvalPolicy}
          onApprovalPolicyChange={handleApprovalPolicyChange}
          projectPath={session?.project_path || session?.repository_root}
          skills={liveSkills}
          session={session}
          tokenUsage={tokenUsage}
          isPinned={scrollAnchor.isPinned.value}
          unreadCount={unreadCount}
          onScrollToBottom={scrollAnchor.scrollToBottom}
          onModelChange={handleModelChange}
        />
        <CapabilitiesPanel
          open={capabilitiesOpen}
          onClose={() => setCapabilitiesOpen(false)}
          sessionId={sessionId}
          liveSkills={liveSkills}
          liveMcpTools={liveMcpTools}
        />
      </div>

      {/* ── Right column: review panel (desktop split / mobile overlay) ─── */}
      {reviewOpen && (
        <div class={styles.reviewCol}>
          <ReviewPanel
            sessionId={sessionId}
            onClose={handleCloseReview}
          />
        </div>
      )}
    </div>
  )
}

export { SessionPage }
