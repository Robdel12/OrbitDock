import styles from './filter-toolbar.module.css'

const PROVIDERS = ['all', 'claude', 'codex']
const STATUSES = ['all', 'active', 'ended']
const SORT_OPTIONS = [
  { value: 'activity', label: 'Last activity' },
  { value: 'name', label: 'Name' },
  { value: 'status', label: 'Status' },
]

const ToggleGroup = ({ options, value, onChange, getLabel }) => (
  <div class={styles.toggleGroup}>
    {options.map((opt) => (
      <button
        key={opt}
        class={styles.toggle}
        data-active={opt === value}
        onClick={() => onChange(opt)}
      >
        {getLabel ? getLabel(opt) : opt}
      </button>
    ))}
  </div>
)

const FilterToolbar = ({ filters, onFiltersChange, sort, onSortChange, repos }) => {
  const setProvider = (provider) => onFiltersChange({ ...filters, provider })
  const setStatus = (status) => onFiltersChange({ ...filters, status })
  const setRepo = (e) => onFiltersChange({ ...filters, repo: e.target.value })

  const providerLabel = (p) => p === 'all' ? 'All' : p.charAt(0).toUpperCase() + p.slice(1)
  const statusLabel = (s) => s === 'all' ? 'All' : s.charAt(0).toUpperCase() + s.slice(1)

  return (
    <div class={styles.toolbar}>
      <div class={styles.row}>
        <div class={styles.group}>
          <span class={styles.label}>Provider</span>
          <ToggleGroup
            options={PROVIDERS}
            value={filters.provider}
            onChange={setProvider}
            getLabel={providerLabel}
          />
        </div>

        <div class={styles.group}>
          <span class={styles.label}>Status</span>
          <ToggleGroup
            options={STATUSES}
            value={filters.status}
            onChange={setStatus}
            getLabel={statusLabel}
          />
        </div>

        {repos.length > 1 && (
          <div class={styles.group}>
            <span class={styles.label}>Repo</span>
            <select
              class={styles.select}
              value={filters.repo}
              onChange={setRepo}
            >
              <option value="all">All repos</option>
              {repos.map((r) => (
                <option key={r.path} value={r.path}>{r.name}</option>
              ))}
            </select>
          </div>
        )}

        <div class={`${styles.group} ${styles.sortGroup}`}>
          <span class={styles.label}>Sort</span>
          <select
            class={styles.select}
            value={sort}
            onChange={(e) => onSortChange(e.target.value)}
          >
            {SORT_OPTIONS.map((opt) => (
              <option key={opt.value} value={opt.value}>{opt.label}</option>
            ))}
          </select>
        </div>
      </div>
    </div>
  )
}

export { FilterToolbar }
