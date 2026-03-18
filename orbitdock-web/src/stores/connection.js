import { signal } from '@preact/signals'
import { createActor } from 'xstate'
import { connectionMachine } from '../machines/connection.machine.js'
import { createWsClient } from '../api/ws.js'
import { createHttpClient } from '../api/http.js'
import {
  handleSessionsList,
  handleSessionCreated,
  handleSessionListItemUpdated,
  handleSessionDelta,
  handleSessionEnded,
  handleSessionRemoved,
  selected,
} from './sessions.js'
import { addToast } from './toasts.js'

const wsClient = createWsClient()
const http = createHttpClient('')
const connectionState = signal('disconnected')
const connectionActor = createActor(connectionMachine)
const serverInfo = signal({ isPrimary: false })

let conversationHandler = null
const subscribedSessions = new Set()

const setConversationHandler = (handler) => {
  conversationHandler = handler
}

const subscribeSession = (sessionId) => {
  subscribedSessions.add(sessionId)
  wsClient.send({ type: 'subscribe_session', session_id: sessionId, include_snapshot: false })
}

const unsubscribeSession = (sessionId) => {
  subscribedSessions.delete(sessionId)
  wsClient.send({ type: 'unsubscribe_session', session_id: sessionId })
}

connectionActor.subscribe((snapshot) => {
  connectionState.value = snapshot.value
})

const routeMessage = (msg) => {
  switch (msg.type) {
    case 'sessions_list':
      handleSessionsList(msg.sessions)
      break
    case 'session_created':
      handleSessionCreated(msg.session)
      break
    case 'session_list_item_updated':
      handleSessionListItemUpdated(msg.session)
      break
    case 'session_delta':
      handleSessionDelta(msg.session_id, msg.changes)
      break
    case 'session_ended':
      handleSessionEnded(msg.session_id)
      break
    case 'session_list_item_removed':
      handleSessionRemoved(msg.session_id)
      break
    case 'server_info':
      serverInfo.value = { isPrimary: msg.is_primary }
      break
    case 'error':
      console.warn('[ws] server error:', msg.code, msg.message)
      break
    case 'approval_requested':
      if (msg.session_id !== selected.value?.id) {
        addToast({
          title: 'Approval needed',
          body: 'A session is waiting for your input.',
          type: 'attention',
          sessionId: msg.session_id,
        })
      }
      if (conversationHandler) conversationHandler(msg)
      break
    case 'rate_limit_event':
      addToast({
        title: 'Rate limited',
        body: msg.info?.provider ? `Provider: ${msg.info.provider}` : undefined,
        type: 'error',
        sessionId: msg.session_id,
      })
      if (conversationHandler) conversationHandler(msg)
      break
    case 'conversation_bootstrap':
    case 'conversation_rows_changed':
    case 'approval_decision_result':
    case 'tokens_updated':
    case 'session_forked':
    case 'context_compacted':
    case 'undo_started':
    case 'undo_completed':
    case 'thread_rolled_back':
    case 'prompt_suggestion':
    case 'files_persisted':
    case 'skills_list':
    case 'mcp_tools_list':
    case 'review_comment_created':
    case 'review_comment_updated':
    case 'review_comment_deleted':
    case 'review_comments_list':
    case 'turn_diff_snapshot':
      if (conversationHandler) conversationHandler(msg)
      break
  }
}

wsClient.lastMessage.subscribe((msg) => {
  if (msg) routeMessage(msg)
})

const fetchInitialSessions = async () => {
  try {
    const data = await http.get('/api/sessions')
    handleSessionsList(data.sessions || [])
  } catch (err) {
    console.warn('[connection] failed to fetch sessions:', err.message)
  }
}

wsClient.status.subscribe((status) => {
  switch (status) {
    case 'connected':
      connectionActor.send({ type: 'WS_OPEN' })
      // WS subscribe_list only delivers incremental updates —
      // initial list must be fetched via REST
      wsClient.send({ type: 'subscribe_list' })
      // Re-subscribe any active session subscriptions (lost on reconnect)
      for (const sid of subscribedSessions) {
        wsClient.send({ type: 'subscribe_session', session_id: sid, include_snapshot: false })
      }
      fetchInitialSessions()
      break
    case 'disconnected':
      if (connectionState.value === 'connected' || connectionState.value === 'connecting') {
        connectionActor.send({ type: 'WS_CLOSE' })
      }
      break
    case 'error':
      connectionActor.send({ type: 'WS_ERROR' })
      break
  }
})

connectionActor.subscribe((snapshot) => {
  if (snapshot.value === 'connecting') {
    const url = snapshot.context.url
    if (url) wsClient.connect(url)
  }
})

connectionActor.start()

const connect = (url) => {
  connectionActor.send({ type: 'CONNECT', url })
}

const disconnect = () => {
  wsClient.disconnect()
  connectionActor.send({ type: 'DISCONNECT' })
}

const sendWs = (msg) => wsClient.send(msg)

export {
  connectionState,
  connectionActor,
  wsClient,
  http,
  connect,
  disconnect,
  sendWs,
  subscribeSession,
  unsubscribeSession,
  setConversationHandler,
  serverInfo,
}
