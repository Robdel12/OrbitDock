import { useState } from 'preact/hooks'
import { useLocation } from 'wouter-preact'
import { SessionList } from '../components/session/session-list.jsx'
import { selectSession, sessions } from '../stores/sessions.js'
import { useKeyboard } from '../hooks/use-keyboard.js'
import styles from './dashboard.module.css'

const DashboardPage = () => {
  const [, navigate] = useLocation()
  const [selectedIndex, setSelectedIndex] = useState(-1)

  const sessionList = [...sessions.value.values()]

  const handleSelect = (id) => {
    selectSession(id)
    navigate(`/session/${id}`)
  }

  useKeyboard({
    ArrowDown: () => setSelectedIndex((i) => Math.min(i + 1, sessionList.length - 1)),
    ArrowUp: () => setSelectedIndex((i) => Math.max(i - 1, 0)),
    j: () => setSelectedIndex((i) => Math.min(i + 1, sessionList.length - 1)),
    k: () => setSelectedIndex((i) => Math.max(i - 1, 0)),
    Enter: () => {
      if (selectedIndex >= 0 && selectedIndex < sessionList.length) {
        handleSelect(sessionList[selectedIndex].id)
      }
    },
  })

  return (
    <div class={styles.page}>
      <SessionList onSelect={handleSelect} />
    </div>
  )
}

export { DashboardPage }
