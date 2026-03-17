import { useEffect, useMemo } from 'preact/hooks'
import { useRoute, useLocation } from 'wouter-preact'
import { createConversationStore } from '../stores/conversation.js'
import { selectSession, selected } from '../stores/sessions.js'
import { sendWs, setConversationHandler } from '../stores/connection.js'
import { useSession } from '../hooks/use-session.js'
import { ConversationView } from '../components/conversation/conversation-view.jsx'
import { MessageComposer } from '../components/input/message-composer.jsx'
import { ApprovalBanner } from '../components/approval/approval-banner.jsx'
import { SessionHeader } from '../components/session/session-header.jsx'
import { createHttpClient } from '../api/http.js'
import { useMachine } from '../hooks/use-machine.js'
import { useKeyboard } from '../hooks/use-keyboard.js'
import { approvalMachine } from '../machines/approval.machine.js'
import styles from './session.module.css'

const http = createHttpClient('')

const SessionPage = () => {
  const [match, params] = useRoute('/session/:id')
  const [, navigate] = useLocation()
  const sessionId = params?.id

  const conversation = useMemo(() => createConversationStore(), [sessionId])
  const [approvalState, sendApproval] = useMachine(approvalMachine, {
    input: { sessionId },
  })

  useSession(sessionId)

  useKeyboard({
    Escape: () => navigate('/'),
  })

  useEffect(() => {
    if (!sessionId) return
    selectSession(sessionId)

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
      }
    }
    fetchConversation()

    // WS handler for live incremental updates
    const handler = (msg) => {
      if (msg.type === 'conversation_rows_changed' && msg.session_id === sessionId) {
        conversation.applyRowsChanged(msg)
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
      }
    }

    setConversationHandler(handler)
    return () => setConversationHandler(null)
  }, [sessionId])

  if (!sessionId) return null

  const session = selected.value
  const rows = conversation.rows.value
  const approvalSnapshot = approvalState.value
  const pendingRequest =
    approvalSnapshot.value === 'pending' ? approvalSnapshot.context.request : null

  const handleSend = (content) => {
    sendWs({
      type: 'send_message',
      session_id: sessionId,
      content,
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

  const handleAnswer = (answer) => {
    if (!pendingRequest) return
    sendApproval({ type: 'ANSWER' })
    http.post(`/api/sessions/${sessionId}/answer`, {
      request_id: pendingRequest.id,
      answer,
    }).catch((err) => {
      sendApproval({ type: 'SUBMIT_ERROR', error: err.message })
    })
  }

  const isEnded = session?.status === 'ended' || session?.work_status === 'ended'
  const isWorking = session?.work_status === 'working'

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

  return (
    <div class={styles.page}>
      <SessionHeader
        session={session}
        onInterrupt={handleInterrupt}
        onCompact={handleCompact}
        onUndo={handleUndo}
        onEnd={handleEnd}
      />
      {pendingRequest && (
        <ApprovalBanner
          request={pendingRequest}
          onDecide={handleDecide}
          onAnswer={handleAnswer}
        />
      )}
      <ConversationView
        rows={rows}
        isLoadingHistory={conversation.isLoadingHistory.value}
        hasMoreBefore={conversation.hasMoreBefore.value}
        onLoadOlder={() => conversation.loadOlder(http, sessionId)}
      />
      <MessageComposer
        onSend={handleSend}
        onInterrupt={handleInterrupt}
        disabled={isEnded}
        isWorking={isWorking}
      />
    </div>
  )
}

export { SessionPage }
