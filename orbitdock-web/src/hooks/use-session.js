import { useEffect } from 'preact/hooks'
import { subscribeSession, unsubscribeSession } from '../stores/connection.js'

const useSession = (sessionId) => {
  useEffect(() => {
    if (!sessionId) return
    subscribeSession(sessionId)
    return () => {
      unsubscribeSession(sessionId)
    }
  }, [sessionId])
}

export { useSession }
