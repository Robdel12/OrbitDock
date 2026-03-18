import styles from './provider-controls.module.css'

// ---------------------------------------------------------------------------
// Segmented control — shared primitive for both pickers
// ---------------------------------------------------------------------------

const SegmentedControl = ({ options, value, onChange, colorVar }) => (
  <div class={styles.segmented}>
    {options.map((opt) => (
      <button
        key={opt.value}
        type="button"
        class={`${styles.segment} ${value === opt.value ? styles.segmentActive : ''}`}
        style={value === opt.value && colorVar ? { '--segment-color': colorVar } : undefined}
        onClick={() => onChange(opt.value)}
        title={opt.description}
      >
        {opt.label}
      </button>
    ))}
  </div>
)

// ---------------------------------------------------------------------------
// Codex effort picker
// ---------------------------------------------------------------------------

const EFFORT_OPTIONS = [
  { value: 'low',    label: 'Low',    description: 'Faster, uses less compute' },
  { value: 'medium', label: 'Med',    description: 'Balanced effort (default)' },
  { value: 'high',   label: 'High',   description: 'Slower, higher quality' },
]

const CodexEffortPicker = ({ value, onChange }) => (
  <div class={styles.control}>
    <span class={styles.label}>Effort</span>
    <SegmentedControl
      options={EFFORT_OPTIONS}
      value={value}
      onChange={onChange}
      colorVar="var(--color-provider-codex)"
    />
  </div>
)

// ---------------------------------------------------------------------------
// Claude permission policy picker
// ---------------------------------------------------------------------------

const POLICY_OPTIONS = [
  { value: 'ask',       label: 'Ask',        description: 'Ask before every tool call' },
  { value: 'auto-edit', label: 'Auto-Edit',  description: 'Auto-approve file edits' },
  { value: 'auto-full', label: 'Auto-Full',  description: 'Auto-approve everything' },
]

const ClaudePermissionPicker = ({ value, onChange }) => (
  <div class={styles.control}>
    <span class={styles.label}>Permissions</span>
    <SegmentedControl
      options={POLICY_OPTIONS}
      value={value}
      onChange={onChange}
      colorVar="var(--color-provider-claude)"
    />
  </div>
)

// ---------------------------------------------------------------------------
// ProviderControls — renders the right control based on provider
// ---------------------------------------------------------------------------

const ProviderControls = ({ provider, effort, onEffortChange, approvalPolicy, onApprovalPolicyChange }) => {
  if (provider === 'codex') {
    return (
      <CodexEffortPicker
        value={effort}
        onChange={onEffortChange}
      />
    )
  }

  if (provider === 'claude') {
    return (
      <ClaudePermissionPicker
        value={approvalPolicy}
        onChange={onApprovalPolicyChange}
      />
    )
  }

  return null
}

export { ProviderControls, SegmentedControl }
