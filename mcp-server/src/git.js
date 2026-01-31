/**
 * Git utilities - pure functions for git operations
 */

import { execSync } from 'node:child_process'
import { basename } from 'node:path'

/**
 * Get current branch name
 */
export const getCurrentBranch = (cwd) => {
  try {
    return execSync('git branch --show-current', { cwd, encoding: 'utf-8' }).trim()
  } catch {
    return null
  }
}

/**
 * Get the main/master branch name
 */
export const getMainBranch = (cwd) => {
  try {
    // Check for main first, then master
    const branches = execSync('git branch -l main master', { cwd, encoding: 'utf-8' })
    if (branches.includes('main')) return 'main'
    if (branches.includes('master')) return 'master'
    return 'main' // Default assumption
  } catch {
    return 'main'
  }
}

/**
 * Check if current branch is a feature branch (not main/master)
 */
export const isFeatureBranch = (cwd) => {
  const branch = getCurrentBranch(cwd)
  if (!branch) return false
  return !['main', 'master', 'develop', 'dev'].includes(branch)
}

/**
 * Get repo root path
 */
export const getRepoRoot = (cwd) => {
  try {
    return execSync('git rev-parse --show-toplevel', { cwd, encoding: 'utf-8' }).trim()
  } catch {
    return null
  }
}

/**
 * Get repo name from path
 */
export const getRepoName = (cwd) => {
  const root = getRepoRoot(cwd)
  return root ? basename(root) : basename(cwd)
}

/**
 * Get GitHub remote info (owner/name)
 */
export const getGitHubRemote = (cwd) => {
  try {
    const remoteUrl = execSync('git remote get-url origin', { cwd, encoding: 'utf-8' }).trim()

    // Parse SSH format: git@github.com:owner/repo.git
    let match = remoteUrl.match(/github\.com[:/]([^/]+)\/([^/.]+)/)
    if (match) {
      return { owner: match[1], name: match[2] }
    }

    // Parse HTTPS format: https://github.com/owner/repo.git
    match = remoteUrl.match(/github\.com\/([^/]+)\/([^/.]+)/)
    if (match) {
      return { owner: match[1], name: match[2] }
    }

    return null
  } catch {
    return null
  }
}

/**
 * Detect if a tool invocation is creating a new branch
 * Returns the new branch name if detected, null otherwise
 */
export const detectBranchCreation = (toolName, toolInput) => {
  if (toolName !== 'Bash') return null

  const command = toolInput?.command || ''

  // git checkout -b <branch>
  let match = command.match(/git\s+checkout\s+-b\s+["']?([^\s"']+)["']?/)
  if (match) return match[1]

  // git switch -c <branch>
  match = command.match(/git\s+switch\s+-c\s+["']?([^\s"']+)["']?/)
  if (match) return match[1]

  // git branch <branch> (without checkout)
  match = command.match(/git\s+branch\s+(?!-[dDm])["']?([^\s"']+)["']?/)
  if (match) return match[1]

  // git worktree add -b <branch>
  match = command.match(/git\s+worktree\s+add\s+.*-b\s+["']?([^\s"']+)["']?/)
  if (match) return match[1]

  return null
}

/**
 * Get commit count on current branch vs main
 */
export const getCommitCount = (cwd) => {
  try {
    const main = getMainBranch(cwd)
    const count = execSync(`git rev-list --count ${main}..HEAD`, { cwd, encoding: 'utf-8' }).trim()
    return parseInt(count, 10) || 0
  } catch {
    return 0
  }
}

/**
 * Get diff stats (additions/deletions) vs main
 */
export const getDiffStats = (cwd) => {
  try {
    const main = getMainBranch(cwd)
    const stats = execSync(`git diff --shortstat ${main}...HEAD`, { cwd, encoding: 'utf-8' }).trim()

    const additions = stats.match(/(\d+) insertion/)
    const deletions = stats.match(/(\d+) deletion/)

    return {
      additions: additions ? parseInt(additions[1], 10) : 0,
      deletions: deletions ? parseInt(deletions[1], 10) : 0,
    }
  } catch {
    return { additions: 0, deletions: 0 }
  }
}
