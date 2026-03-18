import { createActor } from 'xstate'
import { signal } from '@preact/signals'
import { useRef, useEffect } from 'preact/hooks'

const useMachine = (machine, options) => {
  const ref = useRef(null)
  if (!ref.current) {
    const actor = createActor(machine, options)
    const state = signal(actor.getSnapshot())
    actor.subscribe((snapshot) => {
      state.value = snapshot
    })
    actor.start()
    ref.current = { state, send: actor.send.bind(actor), actor }
  }
  useEffect(() => {
    return () => {
      if (ref.current) ref.current.actor.stop()
    }
  }, [])
  return [ref.current.state, ref.current.send]
}

export { useMachine }
