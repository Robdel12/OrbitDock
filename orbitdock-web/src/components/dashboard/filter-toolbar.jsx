import { useState, useRef, useEffect } from 'preact/hooks'
import styles from './filter-toolbar.module.css'

// ---------------------------------------------------------------------------
// Filter chip data
// ---------------------------------------------------------------------------

const FILTER_CHIPS = [
  { value: 'all', label: 'All', color: null },
  { value: 'attention', label: 'Attn', icon: 'attention', color: '--color-status-permission' },
  { value: 'working', label: 'Running', icon: 'working', color: '--color-status-working' },
  { value: 'ready', label: 'Ready', icon: 'ready', color: '--color-status-reply' },
]

const SORT_OPTIONS = [
  { value: 'activity', label: 'Recent' },
  { value: 'name', label: 'Name' },
  { value: 'status', label: 'Status' },
]

// ---------------------------------------------------------------------------
// Chip icons
// ---------------------------------------------------------------------------

const ChipIcon = ({ type }) => {
  if (type === 'attention') {
    return (
      <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
        <path d="M8 1a7 7 0 100 14A7 7 0 008 1zm-.5 4a.5.5 0 011 0v3.5a.5.5 0 01-1 0V5zM8 11.5a.75.75 0 110-1.5.75.75 0 010 1.5z" />
      </svg>
    )
  }
  if (type === 'working') {
    return (
      <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
        <path d="M9.3 2.1a.6.6 0 00-1 .4v4H5.5a.6.6 0 00-.5.9l3.2 6.5a.6.6 0 001-.4v-4h2.8a.6.6 0 00.5-.9L9.3 2.1z" />
      </svg>
    )
  }
  if (type === 'ready') {
    return (
      <svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor">
        <path d="M2 3.5A1.5 1.5 0 013.5 2h9A1.5 1.5 0 0114 3.5v7a1.5 1.5 0 01-1.5 1.5H6l-3 2.5V12H3.5A1.5 1.5 0 012 10.5v-7z" />
      </svg>
    )
  }
  return null
}

// ---------------------------------------------------------------------------
// Custom dropdown — replaces native <select>
// ---------------------------------------------------------------------------

const Dropdown = ({ options, value, onChange, label }) => {
  const [open, setOpen] = useState(false)
  const ref = useRef(null)

  useEffect(() => {
    if (!open) return
    const handleClick = (e) => {
      if (ref.current && !ref.current.contains(e.target)) setOpen(false)
    }
    const handleKey = (e) => {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', handleClick)
    document.addEventListener('keydown', handleKey)
    return () => {
      document.removeEventListener('mousedown', handleClick)
      document.removeEventListener('keydown', handleKey)
    }
  }, [open])

  const current = options.find((o) => o.value === value) || options[0]

  return (
    <div class={styles.dropdown} ref={ref}>
      <button
        class={styles.dropdownTrigger}
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        aria-label={label}
      >
        <span>{current.label}</span>
        <svg width="8" height="8" viewBox="0 0 8 8" fill="none" class={`${styles.dropdownChevron} ${open ? styles.dropdownChevronOpen : ''}`}>
          <path d="M1.5 3L4 5.5 6.5 3" stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
      </button>
      {open && (
        <div class={styles.dropdownMenu}>
          {options.map((opt) => (
            <button
              key={opt.value}
              class={`${styles.dropdownItem} ${opt.value === value ? styles.dropdownItemActive : ''}`}
              onClick={() => { onChange(opt.value); setOpen(false) }}
            >
              {opt.label}
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Filter chip
// ---------------------------------------------------------------------------

const FilterChip = ({ chip, active, count, onClick }) => {
  const chipColor = chip.color ? `var(${chip.color})` : null
  const style = chipColor
    ? { '--chip-color': chipColor }
    : undefined

  return (
    <button
      class={`${styles.chip} ${active ? styles.chipActive : ''}`}
      style={style}
      onClick={onClick}
    >
      {chip.icon && (
        <span class={styles.chipIcon}>
          <ChipIcon type={chip.icon} />
        </span>
      )}
      {count != null && <span class={styles.chipCount}>{count}</span>}
      <span class={styles.chipLabel}>{chip.label}</span>
    </button>
  )
}

// ---------------------------------------------------------------------------
// FilterToolbar
// ---------------------------------------------------------------------------

const FilterToolbar = ({ filters, onFiltersChange, sort, onSortChange, repos, zoneCounts }) => {
  const setZoneFilter = (zone) => onFiltersChange({ ...filters, zone })
  const setRepo = (val) => onFiltersChange({ ...filters, repo: val })

  const repoOptions = [
    { value: 'all', label: 'All repos' },
    ...repos.map((r) => ({ value: r.path, label: r.name })),
  ]

  return (
    <div class={styles.toolbar}>
      <div class={styles.chipRow}>
        {FILTER_CHIPS.map((chip) => (
          <FilterChip
            key={chip.value}
            chip={chip}
            active={(filters.zone || 'all') === chip.value}
            count={chip.value === 'all' ? (zoneCounts?.total ?? null) : (zoneCounts?.[chip.value] ?? null)}
            onClick={() => setZoneFilter(chip.value)}
          />
        ))}
      </div>

      <div class={styles.controlsRight}>
        {repos.length > 1 && (
          <Dropdown
            options={repoOptions}
            value={filters.repo}
            onChange={setRepo}
            label="Repository filter"
          />
        )}
        <Dropdown
          options={SORT_OPTIONS}
          value={sort}
          onChange={onSortChange}
          label="Sort order"
        />
      </div>
    </div>
  )
}

export { FilterToolbar }
