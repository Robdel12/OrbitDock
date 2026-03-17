import { useEffect } from 'preact/hooks'

const useKeyboard = (handlers) => {
  useEffect(() => {
    const onKeyDown = (e) => {
      // Don't intercept when typing in inputs
      const tag = e.target.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return

      const handler = handlers[e.key]
      if (handler) {
        e.preventDefault()
        handler(e)
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [handlers])
}

export { useKeyboard }
