import { useState, useRef } from 'preact/hooks'
import { Button } from '../ui/button.jsx'
import styles from './message-composer.module.css'

const MessageComposer = ({ onSend, onInterrupt, disabled, isWorking }) => {
  const [value, setValue] = useState('')
  const inputRef = useRef(null)

  const resize = () => {
    const el = inputRef.current
    if (!el) return
    el.style.height = 'auto'
    el.style.height = Math.min(el.scrollHeight, 200) + 'px'
  }

  const handleInput = (e) => {
    setValue(e.target.value)
    resize()
  }

  const handleSubmit = (e) => {
    e.preventDefault()
    const text = value.trim()
    if (!text || disabled) return
    onSend(text)
    setValue('')
    if (inputRef.current) {
      inputRef.current.style.height = 'auto'
    }
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSubmit(e)
    }
  }

  return (
    <form class={styles.composer} onSubmit={handleSubmit}>
      <textarea
        ref={inputRef}
        class={styles.input}
        placeholder={isWorking ? 'Agent is working...' : 'Send a message...'}
        rows={1}
        disabled={disabled}
        value={value}
        onInput={handleInput}
        onKeyDown={handleKeyDown}
      />
      <div class={styles.actions}>
        {isWorking && onInterrupt && (
          <Button variant="danger" size="sm" type="button" onClick={onInterrupt}>
            Stop
          </Button>
        )}
        <Button variant="primary" size="sm" type="submit" disabled={disabled || !value.trim()}>
          Send
        </Button>
      </div>
    </form>
  )
}

export { MessageComposer }
