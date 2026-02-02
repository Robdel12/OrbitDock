import ArgumentParser
import Foundation
import OrbitDockCore

struct SessionStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session-start",
        abstract: "Handle SessionStart hook from Claude Code"
    )

    func run() throws {
        let input = try readInput(SessionStartInput.self)

        guard !input.session_id.isEmpty else {
            throw CLIError.invalidInput("Missing session_id")
        }
        guard !input.cwd.isEmpty else {
            throw CLIError.invalidInput("Missing cwd")
        }

        let db = try CLIDatabase()

        // Clean up stale sessions from this terminal
        let terminalId = getTerminalSessionId()
        if let tid = terminalId {
            _ = try db.cleanupStaleSessions(terminalId: tid, currentSessionId: input.session_id)
        }

        // Get git info
        let branch = GitOperations.getCurrentBranch(in: input.cwd)
        let repoRoot = GitOperations.getRepoRoot(in: input.cwd)
        let repoName = GitOperations.getRepoName(in: input.cwd)
        let github = GitOperations.getGitHubRemote(in: input.cwd)

        // Get or create workstream (returns nil for main/master)
        var workstream: WorkstreamRow? = nil
        if let branch = branch, GitOperations.isFeatureBranch(in: input.cwd) {
            workstream = try db.getOrCreateWorkstream(
                projectPath: input.cwd,
                branch: branch,
                repoRoot: repoRoot,
                repoName: repoName,
                githubOwner: github?.owner,
                githubName: github?.name
            )
        }

        // Upsert session
        try db.upsertSession(
            id: input.session_id,
            projectPath: input.cwd,
            projectName: repoName,
            branch: branch,
            model: input.model,
            contextLabel: input.context_label,
            transcriptPath: input.transcript_path,
            status: "active",
            workStatus: "unknown",
            startedAt: CLIDatabase.formatDate(),
            workstreamId: workstream?.id,
            terminalSessionId: terminalId,
            terminalApp: getTerminalApp()
        )

        // Update workstream stats
        if let ws = workstream {
            try db.updateWorkstreamActivity(id: ws.id, incrementSessionCount: true)
        }

        // Notify the app
        db.notifyApp()
    }
}
