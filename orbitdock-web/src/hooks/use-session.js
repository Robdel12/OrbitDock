import { useEffect } from 'preact/hooks'
import { sendWs } from '../stores/connection.js'

const useSession = (sessionId) => {
  useEffect(() => {
    if (!sessionId) return
    sendWs({ type: 'subscribe_session', session_id: sessionId, include_snapshot: false })
    return () => {
      sendWs({ type: 'unsubscribe_session', session_id: sessionId })
    }
  }, [sessionId])
}

export { useSession }
