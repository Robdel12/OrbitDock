import { Button } from '../ui/button.jsx'
import { Card } from '../ui/card.jsx'
import styles from './approval-banner.module.css'

const ApprovalBanner = ({ request, onDecide, onAnswer }) => {
  if (!request) return null

  const renderContent = () => {
    switch (request.type) {
      case 'exec':
        return (
          <div class={styles.body}>
            <p class={styles.title}>Tool wants to run a command</p>
            {request.command && (
              <pre class={styles.preview}>{request.command}</pre>
            )}
            {request.preview && (
              <pre class={styles.preview}>{request.preview.value}</pre>
            )}
            <div class={styles.actions}>
              <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
                Allow
              </Button>
              <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
                Deny
              </Button>
            </div>
          </div>
        )
      case 'patch':
        return (
          <div class={styles.body}>
            <p class={styles.title}>Tool wants to edit a file</p>
            {request.file_path && (
              <p class={styles.subtitle}>{request.file_path}</p>
            )}
            <div class={styles.actions}>
              <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
                Allow
              </Button>
              <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
                Deny
              </Button>
            </div>
          </div>
        )
      case 'question':
        return (
          <div class={styles.body}>
            <p class={styles.title}>{request.question || 'Agent has a question'}</p>
            {request.question_prompts?.map((prompt) => (
              <div key={prompt.id} class={styles.questionGroup}>
                <p class={styles.questionText}>{prompt.question}</p>
                {prompt.options?.length > 0 && (
                  <div class={styles.options}>
                    {prompt.options.map((opt) => (
                      <Button
                        key={opt.label}
                        variant="secondary"
                        size="sm"
                        onClick={() => onAnswer(opt.label)}
                      >
                        {opt.label}
                      </Button>
                    ))}
                  </div>
                )}
              </div>
            ))}
          </div>
        )
      case 'permissions':
        return (
          <div class={styles.body}>
            <p class={styles.title}>Permission request</p>
            {request.permission_reason && (
              <p class={styles.subtitle}>{request.permission_reason}</p>
            )}
            <div class={styles.actions}>
              <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
                Grant
              </Button>
              <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
                Deny
              </Button>
            </div>
          </div>
        )
      default:
        return (
          <div class={styles.body}>
            <p class={styles.title}>Approval needed</p>
            <div class={styles.actions}>
              <Button variant="primary" size="sm" onClick={() => onDecide('approved')}>
                Allow
              </Button>
              <Button variant="danger" size="sm" onClick={() => onDecide('denied')}>
                Deny
              </Button>
            </div>
          </div>
        )
    }
  }

  return (
    <Card edgeColor="status-permission" class={styles.banner}>
      {renderContent()}
    </Card>
  )
}

export { ApprovalBanner }
