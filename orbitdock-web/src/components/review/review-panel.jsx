import { useState, useRef, useEffect } from 'preact/hooks'
import { useKeyboard } from '../../hooks/use-keyboard.js'
import { parseDiff } from '../../lib/parse-diff.js'
import { FileNavigator } from './file-navigator.jsx'
import { CommentThread } from './comment-thread.jsx'
import {
  diffData,
  diffLoading,
  reviewError,
  reviewComments,
  activeFile,
  closeReviewPanel,
} from '../../stores/review.js'
import styles from './review-panel.module.css'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/**
 * Parse the diff data returned by the server into a list of per-file entries.
 * Shape: { path, status, additions, deletions, diff, parsedLines }[]
 */
const buildFileList = (data) => {
  if (!data) return []

  // Handle both `{ files: [...] }` and flat raw diff string
  if (data.files && Array.isArray(data.files)) {
    return data.files.map((f) => ({
      path: f.path || f.filename || '',
      status: f.status || 'modified',
      additions: f.additions ?? 0,
      deletions: f.deletions ?? 0,
      diff: f.diff || f.patch || '',
      parsedLines: parseDiff(f.diff || f.patch || ''),
    }))
  }

  // Fallback: the whole thing is a unified diff string
  if (typeof data === 'string' || typeof data.raw_diff === 'string') {
    const raw = typeof data === 'string' ? data : data.raw_diff
    return splitUnifiedDiff(raw)
  }

  return []
}

/**
 * Split a unified diff string by file (--- / +++ headers) into per-file entries.
 */
const splitUnifiedDiff = (raw) => {
  if (!raw) return []
  const files = []
  const lines = raw.split('\n')
  let currentPath = null
  let currentLines = []
  let currentAdditions = 0
  let currentDeletions = 0

  const flush = () => {
    if (currentPath) {
      files.push({
        path: currentPath,
        status: currentAdditions > 0 && currentDeletions === 0 ? 'added'
          : currentAdditions === 0 && currentDeletions > 0 ? 'deleted'
          : 'modified',
        additions: currentAdditions,
        deletions: currentDeletions,
        diff: currentLines.join('\n'),
        parsedLines: parseDiff(currentLines.join('\n')),
      })
    }
  }

  for (const line of lines) {
    if (line.startsWith('+++ b/') || line.startsWith('+++ ')) {
      flush()
      currentPath = line.startsWith('+++ b/') ? line.slice(6) : line.slice(4)
      currentLines = []
      currentAdditions = 0
      currentDeletions = 0
    } else if (line.startsWith('--- ') || line.startsWith('diff --git ')) {
      // Skip — we key off +++ lines
    } else if (currentPath) {
      currentLines.push(line)
      if (line.startsWith('+') && !line.startsWith('+++')) currentAdditions++
      if (line.startsWith('-') && !line.startsWith('---')) currentDeletions++
    }
  }
  flush()
  return files
}

// ---------------------------------------------------------------------------
// Context collapse — hide long unchanged runs
// ---------------------------------------------------------------------------

const CONTEXT_COLLAPSE_THRESHOLD = 8

const CollapseRow = ({ count, onExpand }) => (
  <button class={styles.collapseRow} onClick={onExpand}>
    ... {count} unchanged line{count !== 1 ? 's' : ''} hidden — click to expand
  </button>
)

/** Render a list of parsed diff lines with context collapsing + comment support. */
const DiffLines = ({ lines, filePath, lineComments, sessionId, onOpenThread }) => {
  const [expandedRanges, setExpandedRanges] = useState([])
  const [activeLineKey, setActiveLineKey] = useState(null)

  // Build collapse groups: runs of context lines longer than the threshold
  const segments = []
  let i = 0

  while (i < lines.length) {
    const line = lines[i]

    // Check if this starts a long context run
    if (line.kind === 'context') {
      let j = i
      while (j < lines.length && lines[j].kind === 'context') j++
      const runLen = j - i

      const isExpanded = expandedRanges.some(([s, e]) => s <= i && e >= j - 1)

      if (runLen > CONTEXT_COLLAPSE_THRESHOLD && !isExpanded) {
        // Show 3 lines at start and end, collapse the middle
        const headEnd = Math.min(i + 3, j)
        const tailStart = Math.max(j - 3, headEnd)
        const collapseCount = tailStart - headEnd

        for (let k = i; k < headEnd; k++) segments.push({ type: 'line', idx: k })
        if (collapseCount > 0) {
          // runStart/runEnd track the full run so expanding marks the entire run as seen
          segments.push({ type: 'collapse', start: headEnd, end: tailStart, runStart: i, runEnd: j - 1, count: collapseCount })
        }
        for (let k = tailStart; k < j; k++) segments.push({ type: 'line', idx: k })
        i = j
        continue
      }
    }

    segments.push({ type: 'line', idx: i })
    i++
  }

  // Store the full run's [start, end] so the isExpanded check works correctly
  const handleExpand = (runStart, runEnd) => {
    setExpandedRanges((prev) => [...prev, [runStart, runEnd]])
  }

  const handleLineClick = (line) => {
    if (line.kind === 'deletion') return // Only comment on additions and context
    const key = `${line.new_line ?? line.old_line}`
    setActiveLineKey(activeLineKey === key ? null : key)
    onOpenThread?.(line)
  }

  return (
    <div class={styles.diffLines}>
      {segments.map((seg, si) => {
        if (seg.type === 'collapse') {
          return (
            <CollapseRow
              key={`collapse-${seg.start}`}
              count={seg.count}
              onExpand={() => handleExpand(seg.runStart, seg.runEnd)}
            />
          )
        }

        const line = lines[seg.idx]
        const lineKey = `${line.new_line ?? line.old_line}`
        const commentsForLine = lineComments?.get(line.new_line ?? 0) || []
        const isActive = activeLineKey === lineKey

        const kindClass =
          line.kind === 'addition' ? styles.lineAdded
          : line.kind === 'deletion' ? styles.lineRemoved
          : styles.lineContext

        return (
          <div key={`line-${seg.idx}`}>
            <div
              class={`${styles.diffLine} ${kindClass} ${isActive ? styles.diffLineActive : ''}`}
              onClick={() => handleLineClick(line)}
              role="button"
              tabIndex={0}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  handleLineClick(line)
                }
              }}
            >
              <span class={styles.lineNum}>{line.old_line ?? ''}</span>
              <span class={styles.lineNum}>{line.new_line ?? ''}</span>
              <span class={styles.prefix}>
                {line.kind === 'addition' ? '+' : line.kind === 'deletion' ? '-' : ' '}
              </span>
              <span class={styles.lineContent}>{line.content}</span>
              {commentsForLine.length > 0 && (
                <span class={styles.commentBadge} title={`${commentsForLine.length} comment(s)`}>
                  {commentsForLine.length}
                </span>
              )}
            </div>
            {(isActive || commentsForLine.length > 0) && (
              <CommentThread
                comments={commentsForLine}
                sessionId={sessionId}
                filePath={filePath}
                lineNumber={line.new_line ?? line.old_line}
                onClose={() => setActiveLineKey(null)}
              />
            )}
          </div>
        )
      })}
    </div>
  )
}

// ---------------------------------------------------------------------------
// FileSection — one file's header + diff
// ---------------------------------------------------------------------------

const FileSection = ({ file, comments, sessionId, sectionRef }) => {
  const [collapsed, setCollapsed] = useState(false)
  const lineComments = comments?.get(file.path)

  const statusClass =
    file.status === 'added' ? styles.fileStatusAdded
    : file.status === 'deleted' ? styles.fileStatusDeleted
    : styles.fileStatusModified

  const statusLabel =
    file.status === 'added' ? 'Added'
    : file.status === 'deleted' ? 'Deleted'
    : 'Modified'

  return (
    <div class={styles.fileSection} ref={sectionRef} data-file={file.path}>
      <button
        class={styles.fileHeader}
        onClick={() => setCollapsed((v) => !v)}
        aria-expanded={!collapsed}
      >
        <span class={`${styles.fileStatusLabel} ${statusClass}`}>{statusLabel}</span>
        <span class={styles.filePath}>{file.path}</span>
        <span class={styles.fileStats}>
          {file.additions > 0 && <span class={styles.fileStat} style="color: var(--color-diff-added-accent)">+{file.additions}</span>}
          {file.deletions > 0 && <span class={styles.fileStat} style="color: var(--color-diff-removed-accent)">-{file.deletions}</span>}
        </span>
        <span class={styles.collapseIcon} aria-hidden="true">
          {collapsed ? '▶' : '▼'}
        </span>
      </button>

      {!collapsed && (
        <div class={styles.fileDiff}>
          {file.parsedLines.length > 0 ? (
            <DiffLines
              lines={file.parsedLines}
              filePath={file.path}
              lineComments={lineComments}
              sessionId={sessionId}
            />
          ) : (
            <div class={styles.emptyDiff}>No diff content available</div>
          )}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// ReviewPanel
// ---------------------------------------------------------------------------

/**
 * Props:
 *   sessionId  — current session ID (used for creating comments)
 *   onClose()  — called when user closes the panel
 */
const ReviewPanel = ({ sessionId, onClose }) => {
  const data = diffData.value
  const loading = diffLoading.value
  const error = reviewError.value
  const comments = reviewComments.value
  const currentFile = activeFile.value

  const files = buildFileList(data)
  const sectionRefs = useRef({})

  const scrollToFile = (path) => {
    const el = sectionRefs.current[path]
    if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' })
  }

  // Keyboard shortcuts scoped to panel
  useKeyboard({
    Escape: () => {
      closeReviewPanel()
      onClose?.()
    },
    ']': () => {
      if (files.length === 0) return
      const idx = currentFile ? files.findIndex((f) => f.path === currentFile) : -1
      const next = files[Math.min(idx + 1, files.length - 1)]
      activeFile.value = next.path
      scrollToFile(next.path)
    },
    '[': () => {
      if (files.length === 0) return
      const idx = currentFile ? files.findIndex((f) => f.path === currentFile) : 1
      const prev = files[Math.max(idx - 1, 0)]
      activeFile.value = prev.path
      scrollToFile(prev.path)
    },
  })

  // Scroll to file when navigator selection changes
  useEffect(() => {
    if (currentFile) scrollToFile(currentFile)
  }, [currentFile])

  // Select first file by default once data loads
  useEffect(() => {
    if (files.length > 0 && !activeFile.value) {
      activeFile.value = files[0].path
    }
  }, [files.length])

  const handleNavigatorSelect = (path) => {
    activeFile.value = path
    scrollToFile(path)
  }

  const handleClose = () => {
    closeReviewPanel()
    onClose?.()
  }

  return (
    <div class={styles.panel}>
      {/* ── Navigator (left / top on mobile) ────────────────────────────── */}
      <div class={styles.navigatorPane}>
        <FileNavigator files={files} onSelect={handleNavigatorSelect} />
      </div>

      {/* ── Main diff area ───────────────────────────────────────────────── */}
      <div class={styles.diffPane}>
        {/* Toolbar */}
        <div class={styles.toolbar}>
          <span class={styles.toolbarTitle}>Code Review</span>
          <div class={styles.toolbarHints}>
            <span class={styles.hint}><kbd>]</kbd><kbd>[</kbd> files</span>
            <span class={styles.hint}><kbd>j</kbd><kbd>k</kbd> nav</span>
          </div>
          <button class={styles.closeBtn} onClick={handleClose} aria-label="Close review panel">
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2 2l8 8M10 2l-8 8"/></svg>
          </button>
        </div>

        {/* Content */}
        <div class={styles.diffScroll}>
          {loading && (
            <div class={styles.loadingState}>
              <span class={styles.spinner} />
              Loading diff…
            </div>
          )}

          {error && !loading && (
            <div class={styles.errorState}>
              Failed to load diff: {error}
            </div>
          )}

          {!loading && !error && files.length === 0 && (
            <div class={styles.emptyState}>
              No file changes found for this session yet.
            </div>
          )}

          {!loading && files.length > 0 && files.map((file) => (
            <FileSection
              key={file.path}
              file={file}
              comments={comments}
              sessionId={sessionId}
              sectionRef={(el) => { sectionRefs.current[file.path] = el }}
            />
          ))}
        </div>
      </div>
    </div>
  )
}

export { ReviewPanel }
