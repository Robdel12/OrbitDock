import { useEffect, useRef } from 'preact/hooks'
import { activeFile } from '../../stores/review.js'
import styles from './file-navigator.module.css'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Group a flat list of file entries by their directory.
 * Returns Map<dirPath, file[]> — '' for top-level files.
 */
const groupByDirectory = (files) => {
  const groups = new Map()
  for (const file of files) {
    const lastSlash = file.path.lastIndexOf('/')
    const dir = lastSlash >= 0 ? file.path.slice(0, lastSlash) : ''
    if (!groups.has(dir)) groups.set(dir, [])
    groups.get(dir).push(file)
  }
  return groups
}

const fileStatusLabel = (status) => {
  switch (status) {
    case 'added': return 'A'
    case 'deleted': return 'D'
    default: return 'M'
  }
}

const fileStatusClass = (status, styles) => {
  switch (status) {
    case 'added': return styles.statusAdded
    case 'deleted': return styles.statusDeleted
    default: return styles.statusModified
  }
}

// ---------------------------------------------------------------------------
// FileRow
// ---------------------------------------------------------------------------

const FileRow = ({ file, isActive, onClick }) => {
  const ref = useRef(null)
  const lastSlash = file.path.lastIndexOf('/')
  const filename = lastSlash >= 0 ? file.path.slice(lastSlash + 1) : file.path

  // Scroll into view when this file becomes active
  useEffect(() => {
    if (isActive && ref.current) {
      ref.current.scrollIntoView({ block: 'nearest', behavior: 'smooth' })
    }
  }, [isActive])

  return (
    <button
      ref={ref}
      class={`${styles.fileRow} ${isActive ? styles.fileRowActive : ''}`}
      onClick={onClick}
      title={file.path}
    >
      <span class={`${styles.statusBadge} ${fileStatusClass(file.status, styles)}`}>
        {fileStatusLabel(file.status)}
      </span>
      <span class={styles.fileName}>{filename}</span>
      {(file.additions > 0 || file.deletions > 0) && (
        <span class={styles.lineCounts}>
          {file.additions > 0 && <span class={styles.additions}>+{file.additions}</span>}
          {file.deletions > 0 && <span class={styles.deletions}>-{file.deletions}</span>}
        </span>
      )}
    </button>
  )
}

// ---------------------------------------------------------------------------
// DirectoryGroup
// ---------------------------------------------------------------------------

const DirectoryGroup = ({ dir, files, currentFile, onSelect }) => (
  <div class={styles.dirGroup}>
    {dir && (
      <div class={styles.dirLabel} title={dir}>
        {dir}/
      </div>
    )}
    {files.map((file) => (
      <FileRow
        key={file.path}
        file={file}
        isActive={currentFile === file.path}
        onClick={() => onSelect(file.path)}
      />
    ))}
  </div>
)

// ---------------------------------------------------------------------------
// FileNavigator
// ---------------------------------------------------------------------------

const FileNavigator = ({ files = [], onSelect }) => {
  const current = activeFile.value
  const groups = groupByDirectory(files)
  const dirs = Array.from(groups.keys()).sort()

  const handleSelect = (path) => {
    activeFile.value = path
    onSelect?.(path)
  }

  // Keyboard navigation: j/k move through files, ] / [ already handled at panel level
  useEffect(() => {
    const flatPaths = files.map((f) => f.path)
    if (flatPaths.length === 0) return

    const onKey = (e) => {
      const tag = e.target.tagName
      if (tag === 'INPUT' || tag === 'TEXTAREA') return
      if (e.key !== 'j' && e.key !== 'k' && e.key !== 'ArrowDown' && e.key !== 'ArrowUp') return

      e.preventDefault()
      const idx = current ? flatPaths.indexOf(current) : -1
      if (e.key === 'j' || e.key === 'ArrowDown') {
        const next = flatPaths[Math.min(idx + 1, flatPaths.length - 1)]
        handleSelect(next)
      } else {
        const prev = flatPaths[Math.max(idx - 1, 0)]
        handleSelect(prev)
      }
    }

    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [files, current])

  if (files.length === 0) {
    return (
      <div class={styles.empty}>No files changed</div>
    )
  }

  return (
    <nav class={styles.navigator} aria-label="Changed files">
      <div class={styles.header}>
        <span class={styles.headerLabel}>Files changed</span>
        <span class={styles.fileCount}>{files.length}</span>
      </div>
      <div class={styles.list}>
        {dirs.map((dir) => (
          <DirectoryGroup
            key={dir || '__root__'}
            dir={dir}
            files={groups.get(dir)}
            currentFile={current}
            onSelect={handleSelect}
          />
        ))}
      </div>
    </nav>
  )
}

export { FileNavigator }
