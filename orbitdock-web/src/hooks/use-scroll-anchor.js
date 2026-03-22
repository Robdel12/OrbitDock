import { signal } from '@preact/signals'
import { useCallback, useEffect, useRef } from 'preact/hooks'

const useScrollAnchor = () => {
  const containerRef = useRef(null)
  const sentinelRef = useRef(null)
  const isPinned = signal(true)

  useEffect(() => {
    const sentinel = sentinelRef.current
    if (!sentinel) return
    const observer = new IntersectionObserver(
      ([entry]) => {
        isPinned.value = entry.isIntersecting
      },
      { root: containerRef.current, threshold: 0.1 },
    )
    observer.observe(sentinel)
    return () => observer.disconnect()
  }, [])

  const scrollToBottom = useCallback(() => {
    const container = containerRef.current
    if (container) {
      container.scrollTop = container.scrollHeight
    }
  }, [])

  return { containerRef, sentinelRef, isPinned, scrollToBottom }
}

export { useScrollAnchor }
