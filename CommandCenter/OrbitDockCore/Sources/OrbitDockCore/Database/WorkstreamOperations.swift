import Foundation
import SQLite

// MARK: - Repo Operations

extension CLIDatabase {

    /// Find or create a repo
    public func findOrCreateRepo(
        path: String,
        name: String,
        githubOwner: String?,
        githubName: String?
    ) throws -> RepoRow {
        // Try to find existing
        let query = Self.repos.filter(Self.repoPath == path)
        if let existing = try connection.pluck(query) {
            return RepoRow(
                id: existing[Self.repoId],
                name: existing[Self.repoName],
                path: existing[Self.repoPath]
            )
        }

        // Create new
        let id = Data(path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let now = Self.formatDate()

        try connection.run("""
            INSERT INTO repos (id, name, path, github_owner, github_name, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            id, name, path, githubOwner, githubName, now
        )

        return RepoRow(id: id, name: name, path: path)
    }
}

// MARK: - Workstream Operations

extension CLIDatabase {

    /// Find workstream by branch
    public func findWorkstreamByBranch(repoId: String, branch: String) -> WorkstreamRow? {
        let query = Self.workstreams
            .filter(Self.wsRepoId == repoId)
            .filter(Self.wsBranch == branch)

        guard let row = try? connection.pluck(query) else { return nil }

        return WorkstreamRow(
            id: row[Self.wsId],
            repoId: row[Self.wsRepoId],
            branch: row[Self.wsBranch],
            sessionCount: row[Self.wsSessionCount]
        )
    }

    /// Create a new workstream
    public func createWorkstream(
        repoId: String,
        branch: String,
        directory: String?,
        name: String?
    ) throws -> WorkstreamRow {
        let id = "ws-\(Int(Date().timeIntervalSince1970 * 1000))-\(randomString(6))"
        let now = Self.formatDate()

        try connection.run("""
            INSERT INTO workstreams (
                id, repo_id, branch, directory, name, stage,
                review_approvals, review_comments, session_count,
                total_session_seconds, commit_count, created_at, updated_at,
                is_archived, is_working, has_open_pr, in_review, has_approval, is_merged, is_closed
            ) VALUES (?, ?, ?, ?, ?, 'working', 0, 0, 0, 0, 0, ?, ?, 0, 1, 0, 0, 0, 0, 0)
            """,
            id, repoId, branch, directory, name, now, now
        )

        return WorkstreamRow(id: id, repoId: repoId, branch: branch, sessionCount: 0)
    }

    /// Update workstream activity and session count
    public func updateWorkstreamActivity(id workstreamId: String, incrementSessionCount: Bool = false) throws {
        let now = Self.formatDate()

        if incrementSessionCount {
            try connection.run("""
                UPDATE workstreams SET
                    session_count = session_count + 1,
                    last_activity_at = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                now, now, workstreamId
            )
        } else {
            try connection.run("""
                UPDATE workstreams SET
                    last_activity_at = ?,
                    updated_at = ?
                WHERE id = ?
                """,
                now, now, workstreamId
            )
        }
    }

    /// Get or create workstream for a branch
    /// Returns nil for main/master branches
    public func getOrCreateWorkstream(
        projectPath: String,
        branch: String,
        repoRoot: String?,
        repoName: String,
        githubOwner: String?,
        githubName: String?
    ) throws -> WorkstreamRow? {
        // Skip main branches
        let mainBranches = ["main", "master", "develop", "dev"]
        if mainBranches.contains(branch.lowercased()) {
            return nil
        }

        let root = repoRoot ?? projectPath
        let repo = try findOrCreateRepo(
            path: root,
            name: repoName,
            githubOwner: githubOwner,
            githubName: githubName
        )

        // Check for existing
        if let existing = findWorkstreamByBranch(repoId: repo.id, branch: branch) {
            return existing
        }

        // Create new
        let displayName = branchToDisplayName(branch)
        let directory = projectPath != root ? projectPath : nil

        return try createWorkstream(
            repoId: repo.id,
            branch: branch,
            directory: directory,
            name: displayName
        )
    }
}

// MARK: - Row Models

public struct RepoRow {
    public let id: String
    public let name: String
    public let path: String
}

public struct WorkstreamRow {
    public let id: String
    public let repoId: String
    public let branch: String
    public let sessionCount: Int
}

// MARK: - Helpers

/// Convert branch name to display name
/// e.g., "feat/add-auth-system" -> "Add Auth System"
private func branchToDisplayName(_ branch: String) -> String {
    var name = branch
        // Remove common prefixes
        .replacingOccurrences(
            of: "^(feat|feature|fix|bugfix|chore|refactor|docs|test|ci)/",
            with: "",
            options: .regularExpression
        )
        // Remove ticket prefixes like "VIZ-123-"
        .replacingOccurrences(
            of: "^[A-Za-z]+-\\d+[-_]?",
            with: "",
            options: .regularExpression
        )

    // Convert separators to spaces and title case
    name = name
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)

    return name.isEmpty ? branch : name
}

private func randomString(_ length: Int) -> String {
    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    return String((0..<length).compactMap { _ in chars.randomElement() })
}
