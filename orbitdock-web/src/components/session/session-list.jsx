import { SessionCard } from './session-card.jsx'
import styles from './session-list.module.css'

// `groups` is an array of { path, name, sessions[] } — passed in from the parent
// so that filtering / sorting lives outside this component.
const SessionList = ({ groups, onSelect }) => {

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
