/**
 * Workstream logic - high-level operations combining db and git
 */

import * as db from './db.js'
import * as git from './git.js'

/**
 * Get or create workstream for the current branch
 * Returns null if on main/master branch
 */
export const getOrCreateWorkstream = (database, projectPath) => {
  const branch = git.getCurrentBranch(projectPath)
  if (!branch || !git.isFeatureBranch(projectPath)) {
    return null
  }

  // Ensure repo exists
  const repoRoot = git.getRepoRoot(projectPath) || projectPath
  const repoName = git.getRepoName(projectPath)
  const github = git.getGitHubRemote(projectPath)

  const repo = db.findOrCreateRepo(database, {
    path: repoRoot,
    name: repoName,
    githubOwner: github?.owner,
    githubName: github?.name,
  })

  // Check for existing workstream
  let workstream = db.findWorkstreamByBranch(database, repo.id, branch)

  if (!workstream) {
    // Create new workstream
    workstream = db.createWorkstream(database, {
      repoId: repo.id,
      branch,
      directory: projectPath !== repoRoot ? projectPath : null,
      name: branchToDisplayName(branch),
    })
  }

  return workstream
}

/**
 * Get workstream context for MCP - everything Claude needs to know
 */
export const getWorkstreamContext = (database, projectPath) => {
  const workstream = getOrCreateWorkstream(database, projectPath)

  if (!workstream) {
    return {
      hasWorkstream: false,
      branch: git.getCurrentBranch(projectPath),
      message: 'No active workstream - on main/master branch',
    }
  }

  const full = db.getWorkstreamWithRelations(database, workstream.id)
  const blockers = db.getUnresolvedBlockers(database, workstream.id)

  return {
    hasWorkstream: true,
    workstream: {
      id: workstream.id,
      branch: workstream.branch,
      name: workstream.name,
      description: workstream.description,
      stage: workstream.stage,
      createdAt: workstream.created_at,
    },
    tickets: (full.tickets || []).map((t) => ({
      source: t.source,
      id: t.external_id,
      title: t.title,
      state: t.state,
      url: t.url,
      isPrimary: !!t.is_primary,
    })),
    recentNotes: (full.notes || []).slice(0, 5).map((n) => ({
      type: n.type,
      content: n.content,
      createdAt: n.created_at,
      isResolved: !!n.resolved_at,
    })),
    unresolvedBlockers: blockers.map((b) => ({
      id: b.id,
      content: b.content,
      createdAt: b.created_at,
    })),
    sessionCount: full.sessions?.length || 0,
    stats: {
      commitCount: git.getCommitCount(projectPath),
      ...git.getDiffStats(projectPath),
    },
  }
}

/**
 * Handle session start - create/update session and link to workstream
 */
export const handleSessionStart = (
  database,
  { sessionId, projectPath, model, contextLabel, transcriptPath, terminalSessionId, terminalApp },
) => {
  db.ensureSchema(database)

  // Clean up stale sessions from this terminal
  // A terminal can only run one Claude session at a time
  if (terminalSessionId) {
    db.cleanupStaleSessions(database, terminalSessionId, sessionId)
  }

  const branch = git.getCurrentBranch(projectPath)
  const repoName = git.getRepoName(projectPath)
  const workstream = getOrCreateWorkstream(database, projectPath)

  const session = db.upsertSession(database, {
    id: sessionId,
    projectPath,
    projectName: repoName,
    branch,
    model,
    contextLabel,
    transcriptPath,
    status: 'active',
    workStatus: 'unknown',
    startedAt: new Date().toISOString(),
    workstreamId: workstream?.id,
    terminalSessionId,
    terminalApp,
  })

  // Update workstream stats
  if (workstream) {
    db.updateWorkstream(database, workstream.id, {
      sessionCount: (workstream.session_count || 0) + 1,
      lastActivityAt: new Date().toISOString(),
    })
  }

  return { session, workstream }
}

/**
 * Handle session end
 */
export const handleSessionEnd = (database, { sessionId, reason }) => {
  db.endSession(database, sessionId, reason)

  const session = db.getSession(database, sessionId)
  if (session?.workstream_id) {
    db.updateWorkstream(database, session.workstream_id, {
      lastActivityAt: new Date().toISOString(),
    })
  }

  return { session }
}

/**
 * Handle tool use - detect branch creation, update status
 */
export const handleToolUse = (database, { sessionId, toolName, toolInput, projectPath }) => {
  // Update session activity
  db.updateSession(database, sessionId, {
    lastTool: toolName,
    lastToolAt: new Date().toISOString(),
    workStatus: 'working',
  })

  // Check for branch creation
  const newBranch = git.detectBranchCreation(toolName, toolInput)
  if (newBranch && newBranch !== 'main' && newBranch !== 'master') {
    // New branch created - create workstream
    const repoRoot = git.getRepoRoot(projectPath) || projectPath
    const repoName = git.getRepoName(projectPath)
    const github = git.getGitHubRemote(projectPath)

    const repo = db.findOrCreateRepo(database, {
      path: repoRoot,
      name: repoName,
      githubOwner: github?.owner,
      githubName: github?.name,
    })

    let workstream = db.findWorkstreamByBranch(database, repo.id, newBranch)
    if (!workstream) {
      workstream = db.createWorkstream(database, {
        repoId: repo.id,
        branch: newBranch,
        name: branchToDisplayName(newBranch),
      })

      // Link session to new workstream
      db.updateSession(database, sessionId, {
        workstreamId: workstream.id,
        branch: newBranch,
      })

      return { branchCreated: true, workstream }
    }
  }

  return { branchCreated: false }
}

/**
 * Handle status change (waiting for input, etc)
 */
export const handleStatusChange = (database, { sessionId, status }) => {
  db.updateSession(database, sessionId, {
    workStatus: status,
  })
}

/**
 * Add a note to the current workstream
 */
export const addWorkstreamNote = (database, projectPath, { type, content, sessionId }) => {
  const workstream = getOrCreateWorkstream(database, projectPath)
  if (!workstream) {
    throw new Error('No active workstream - must be on a feature branch')
  }

  return db.addNote(database, {
    workstreamId: workstream.id,
    type,
    content,
    sessionId,
  })
}

/**
 * Link a ticket to the current workstream
 */
export const linkTicket = (
  database,
  projectPath,
  { source, externalId, title, state, url, isPrimary },
) => {
  const workstream = getOrCreateWorkstream(database, projectPath)
  if (!workstream) {
    throw new Error('No active workstream - must be on a feature branch')
  }

  return db.addTicket(database, {
    workstreamId: workstream.id,
    source,
    externalId,
    title,
    state,
    url,
    isPrimary,
  })
}

// ============================================================================
// Helpers
// ============================================================================

/**
 * Convert branch name to display name
 * e.g., "feat/add-auth-system" -> "Add Auth System"
 */
const branchToDisplayName = (branch) => {
  // Remove common prefixes
  let name = branch
    .replace(/^(feat|feature|fix|bugfix|chore|refactor|docs|test|ci)\//i, '')
    .replace(/^[A-Z]+-\d+[-_]?/i, '') // Remove ticket prefixes like "VIZ-123-"

  // Convert separators to spaces and title case
  return (
    name
      .replace(/[-_]/g, ' ')
      .replace(/\b\w/g, (c) => c.toUpperCase())
      .trim() || branch
  )
}
