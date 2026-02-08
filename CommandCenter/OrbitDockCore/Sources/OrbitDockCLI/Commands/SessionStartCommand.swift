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

        if input.isCodexRolloutPayload {
            log("[SessionStart] skipping Codex payload session=\(input.session_id.prefix(8))")
            return
        }

        log("[SessionStart] source=\(input.source ?? "unknown") model=\(input.model ?? "unknown") session=\(input.session_id.prefix(8))")

        let db = try CLIDatabase()

        // Clean up stale sessions from this terminal
        let terminalId = getTerminalSessionId()
        if let tid = terminalId {
            _ = try db.cleanupStaleSessions(terminalId: tid, currentSessionId: input.session_id)
        }

        // Get git info
        let branch = GitOperations.getCurrentBranch(in: input.cwd)
        let repoName = GitOperations.getRepoName(in: input.cwd)

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
            terminalSessionId: terminalId,
            terminalApp: getTerminalApp()
        )

        // Update with additional hook data (source, agent_type, permission_mode)
        try db.updateSession(
            id: input.session_id,
            source: input.source,
            agentType: input.agent_type,
            permissionMode: input.permission_mode
        )

        if let agentType = input.agent_type {
            log("  → agent_type=\(agentType)")
        }

        // Notify the app
        db.notifyApp()
    }
}
