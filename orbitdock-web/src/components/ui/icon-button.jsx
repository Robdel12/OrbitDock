import styles from './icon-button.module.css'

const IconButton = ({ variant = 'ghost', label, children, class: className, ...props }) => (
  <button class={`${styles.iconButton} ${styles[variant]} ${className || ''}`} aria-label={label} {...props}>
    {children}
  </button>
)

export { IconButton }
