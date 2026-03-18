import { Component } from 'preact'
import { Button } from './button.jsx'
import styles from './error-boundary.module.css'

class ErrorBoundary extends Component {
  constructor(props) {
    super(props)
    this.state = { error: null, errorInfo: null }
  }

  static getDerivedStateFromError(error) {
    return { error }
  }

  componentDidCatch(error, info) {
    console.error('[ErrorBoundary]', error, info)
    this.setState({ errorInfo: info })
    this.props.onError?.(error, info)
  }

  render() {
    if (this.state.error) {
      return (
        <div class={styles.container}>
          <div class={styles.card}>
            <div class={styles.edgeLine} aria-hidden="true" />
            <div class={styles.content}>
              <div class={styles.iconRow} aria-hidden="true">⚠</div>
              <h2 class={styles.title}>Something went wrong</h2>
              <p class={styles.message}>{this.state.error.message}</p>
              <Button
                variant="secondary"
                size="sm"
                onClick={() => this.setState({ error: null, errorInfo: null })}
              >
                Try Again
              </Button>
            </div>
          </div>
        </div>
      )
    }
    return this.props.children
  }
}

export { ErrorBoundary }
