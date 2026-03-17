import styles from './badge.module.css'

const Badge = ({ variant = 'meta', color, children, class: className }) => (
  <span
    class={`${styles.badge} ${styles[variant]} ${className || ''}`}
    style={color ? { '--badge-color': `var(--color-${color})` } : undefined}
  >
    {children}
  </span>
)

export { Badge }
