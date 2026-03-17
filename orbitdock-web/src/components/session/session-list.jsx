import { grouped } from '../../stores/sessions.js'
import { SessionCard } from './session-card.jsx'
import styles from './session-list.module.css'

const SessionList = ({ onSelect }) => {
  const groups = grouped.value

  if (groups.length === 0) {
    return <div class={styles.empty}>No sessions yet</div>
  }

  return (
    <div class={styles.list}>
      {groups.map((group) => (
        <div key={group.path} class={styles.group}>
          <div class={styles.groupHeader}>{group.name}</div>
          {group.sessions.map((session) => (
            <SessionCard
              key={session.id}
              session={session}
              onClick={() => onSelect(session.id)}
            />
          ))}
        </div>
      ))}
    </div>
  )
}

export { SessionList }
