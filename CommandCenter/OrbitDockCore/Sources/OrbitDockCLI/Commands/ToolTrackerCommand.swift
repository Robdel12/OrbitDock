import ArgumentParser
import Foundation
import OrbitDockCore

struct ToolTrackerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tool-tracker",
        abstract: "Handle tool events (PreToolUse, PostToolUse, PostToolUseFailure)"
    )

    func run() throws {
        let input = try readInput(ToolTrackerInput.self)

        guard !input.session_id.isEmpty else {
            throw CLIError.invalidInput("Missing session_id")
        }

        let db = try CLIDatabase()

        switch input.hook_event_name {
        case "PreToolUse":
            try handlePreToolUse(
                db: db,
                sessionId: input.session_id,
                cwd: input.cwd,
                toolName: input.tool_name,
                toolInput: input.tool_input
            )

        case "PostToolUse":
            try handlePostToolUse(db: db, sessionId: input.session_id)

        case "PostToolUseFailure":
            try handlePostToolUseFailure(db: db, sessionId: input.session_id)

        default:
            break
        }

        // Notify the app
        db.notifyApp()
    }

    /// Handle PreToolUse - Claude is about to use a tool
    private func handlePreToolUse(
        db: CLIDatabase,
        sessionId: String,
        cwd: String,
        toolName: String,
        toolInput: ToolInput?
    ) throws {
        let now = CLIDatabase.formatDate()

        // Check current session state
        let session = db.getSession(id: sessionId)
        let isInPermission = session?.workStatus == "permission"

        // Prepare pending tool info (only if not already in permission state)
        var pendingToolName: String? = nil
        var pendingToolInput: String? = nil
        var pendingQuestion: String? = nil

        if !isInPermission {
            pendingToolName = toolName

            // Encode tool input as JSON for storage
            if let input = toolInput {
                let encoder = JSONEncoder()
                if let data = try? encoder.encode(input) {
                    pendingToolInput = String(data: data, encoding: .utf8)
                }
            }

            // Extract question from AskUserQuestion
            if toolName == "AskUserQuestion", let question = toolInput?.question {
                pendingQuestion = question
            }
        }

        // Update session
        try db.updateSession(
            id: sessionId,
            workStatus: "working",
            lastTool: toolName,
            lastToolAt: now,
            pendingToolName: pendingToolName,
            pendingToolInput: pendingToolInput,
            pendingQuestion: pendingQuestion
        )

        // Check for branch creation
        if let command = toolInput?.command {
            if let newBranch = GitOperations.detectBranchCreation(toolName: toolName, command: command) {
                // Skip main/master branches
                let mainBranches = ["main", "master", "develop", "dev"]
                if !mainBranches.contains(newBranch.lowercased()) {
                    try handleBranchCreation(
                        db: db,
                        sessionId: sessionId,
                        cwd: cwd,
                        newBranch: newBranch
                    )
                }
            }
        }
    }

    /// Handle PostToolUse - Tool completed successfully
    private func handlePostToolUse(db: CLIDatabase, sessionId: String) throws {
        try db.incrementToolCount(id: sessionId)
        try db.clearPendingFields(id: sessionId)
    }

    /// Handle PostToolUseFailure - Tool failed or was interrupted
    private func handlePostToolUseFailure(db: CLIDatabase, sessionId: String) throws {
        try db.incrementToolCount(id: sessionId)
        try db.clearPendingFields(id: sessionId)
        try db.updateSession(
            id: sessionId,
            workStatus: "waiting",
            attentionReason: "awaitingReply"
        )
    }

    /// Handle branch creation - create workstream and link session
    private func handleBranchCreation(
        db: CLIDatabase,
        sessionId: String,
        cwd: String,
        newBranch: String
    ) throws {
        let repoRoot = GitOperations.getRepoRoot(in: cwd)
        let repoName = GitOperations.getRepoName(in: cwd)
        let github = GitOperations.getGitHubRemote(in: cwd)

        // Get or create workstream for the new branch
        let workstream = try db.getOrCreateWorkstream(
            projectPath: cwd,
            branch: newBranch,
            repoRoot: repoRoot,
            repoName: repoName,
            githubOwner: github?.owner,
            githubName: github?.name
        )

        // Link session to the new workstream
        if let ws = workstream {
            try db.updateSession(
                id: sessionId,
                workstreamId: ws.id,
                branch: newBranch
            )
        }
    }
}
