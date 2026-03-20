import { signal } from '@preact/signals'
import { createActor } from 'xstate'
import { connectionMachine } from '../machines/connection.machine.js'
import { createWsClient } from '../api/ws.js'
import { createHttpClient } from '../api/http.js'
import { clearToken } from './auth.js'
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
// Token accessor reads fresh on every request — no rebuild needed on token change.
// on401 clears the stored token so the auth gate re-appears.
const http = createHttpClient('', () => localStorage.getItem('orbitdock_auth_token') || '', { on401: clearToken })
const connectionState = signal('disconnected')
const connectionActor = createActor(connectionMachine)
const serverInfo = signal({ isPrimary: false })
const authRequired = signal(null) // null = unknown, true/false once probed

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
      wsClient.send({ type: 'subscribe_list' })
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
    if (url) {
      // Append token as query param for WS auth (browsers can't set headers on WebSocket)
      const tok = localStorage.getItem('orbitdock_auth_token') || ''
      const wsUrl = tok ? `${url}${url.includes('?') ? '&' : '?'}token=${encodeURIComponent(tok)}` : url
      wsClient.connect(wsUrl)
    }
  }
})

connectionActor.start()

/** Probe the server: returns 'ok' | 'auth_required' | 'unreachable' */
const probeAuth = async () => {
  try {
    const res = await fetch('/health')
    if (!res.ok) {
      authRequired.value = false
      return 'unreachable'
    }
  } catch {
    authRequired.value = false
    return 'unreachable'
  }

  // Server is up — try an authenticated call to see if auth is needed
  try {
    const tok = localStorage.getItem('orbitdock_auth_token') || ''
    const res = await fetch('/api/sessions', {
      headers: tok ? { Authorization: `Bearer ${tok}` } : {},
    })
    if (res.status === 401) {
      authRequired.value = true
      return 'auth_required'
    }
    authRequired.value = tok ? true : false
    return 'ok'
  } catch {
    authRequired.value = false
    return 'unreachable'
  }
}

const connect = (url) => {
  connectionActor.send({ type: 'CONNECT', url })
}

const disconnect = () => {
  wsClient.disconnect()
  connectionActor.send({ type: 'DISCONNECT' })
}

/** Disconnect and reconnect (e.g. after token change) */
const reconnect = () => {
  const snap = connectionActor.getSnapshot()
  const url = snap.context.url
  if (url) {
    disconnect()
    connect(url)
  }
}

const sendWs = (msg) => wsClient.send(msg)

export {
  connectionState,
  connectionActor,
  wsClient,
  http,
  connect,
  disconnect,
  reconnect,
  sendWs,
  subscribeSession,
  unsubscribeSession,
  setConversationHandler,
  serverInfo,
  authRequired,
  probeAuth,
}
