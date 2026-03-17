import { Card } from '../ui/card.jsx'
import { Badge } from '../ui/badge.jsx'
import styles from './question-row.module.css'

const QuestionRow = ({ entry }) => {
  const row = entry.row

  return (
    <Card edgeColor="status-question" class={styles.card}>
      <div class={styles.title}>{row.title}</div>
      {row.subtitle && <div class={styles.subtitle}>{row.subtitle}</div>}
      {row.prompts?.map((prompt) => (
        <div key={prompt.id} class={styles.prompt}>
          <span class={styles.promptQuestion}>{prompt.question}</span>
          {prompt.options?.length > 0 && (
            <div class={styles.options}>
              {prompt.options.map((opt) => (
                <span key={opt.label} class={styles.option}>{opt.label}</span>
              ))}
            </div>
          )}
        </div>
      ))}
      {row.response && (
        <div class={styles.response}>
          <Badge variant="status" color="feedback-positive">Answered</Badge>
          {typeof row.response === 'string' && (
            <span class={styles.responseText}>{row.response}</span>
          )}
        </div>
      )}
    </Card>
  )
}

export { QuestionRow }
