import styles from './button.module.css'

const Button = ({ variant = 'secondary', size = 'md', loading, disabled, children, class: className, ...props }) => (
  <button
    class={`${styles.button} ${styles[variant]} ${styles[size]} ${className || ''}`}
    disabled={disabled || loading}
    {...props}
  >
    {loading ? <span class={styles.spinner} /> : children}
  </button>
)

export { Button }
