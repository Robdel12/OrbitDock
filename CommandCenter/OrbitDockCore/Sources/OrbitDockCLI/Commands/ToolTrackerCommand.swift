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

        log("[\(input.hook_event_name)] tool=\(input.tool_name) session=\(input.session_id.prefix(8))")

        let db = try CLIDatabase()
        if let session = db.getSession(id: input.session_id), session.provider == "codex" {
            log("  → skipping tool update for codex session")
            return
        }

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
            try handlePostToolUse(
                db: db,
                sessionId: input.session_id,
                toolName: input.tool_name,
                toolInput: input.tool_input,
                toolResponse: input.tool_response
            )

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
        log("  → status=working lastTool=\(toolName)")

        // Update session branch if changed
        if let command = toolInput?.command {
            if let newBranch = GitOperations.detectBranchCreation(toolName: toolName, command: command) {
                // Skip main/master branches for branch tracking
                let mainBranches = ["main", "master", "develop", "dev"]
                if !mainBranches.contains(newBranch.lowercased()) {
                    try db.updateSession(id: sessionId, branch: newBranch)
                }
            }
        }
    }

    /// Handle PostToolUse - Tool completed successfully
    private func handlePostToolUse(
        db: CLIDatabase,
        sessionId: String,
        toolName: String,
        toolInput: ToolInput?,
        toolResponse: ToolResponse?
    ) throws {
        try db.incrementToolCount(id: sessionId)
        try db.clearPendingFields(id: sessionId)
        // Set working status - Claude is actively processing the tool result
        // This clears the "permission" state after a tool runs
        try db.updateSession(
            id: sessionId,
            workStatus: "working",
            attentionReason: "none"
        )
        log("  → status=working reason=none")

        // Detect GitHub PR/issue links from Bash output and link to quest
        if toolName == "Bash",
           let command = toolInput?.command,
           LinkDetector.isGitHubCreateCommand(command),
           let stdout = toolResponse?.stdout {

            let links = LinkDetector.detectLinks(from: stdout, command: command)

            // Only link if session has a quest
            if let questId = db.getQuestIdForSession(sessionId: sessionId) {
                for link in links {
                    if let linkId = db.addQuestLink(
                        questId: questId,
                        source: link.type.rawValue,
                        url: link.url,
                        title: link.title,
                        externalId: "#\(link.number)"
                    ) {
                        log("  → Detected \(link.type.rawValue) #\(link.number), linked to quest: \(linkId.prefix(8))")
                    }
                }
            } else {
                // No quest linked - just log for now
                for link in links {
                    log("  → Detected \(link.type.rawValue) #\(link.number) (no quest linked)")
                }
            }
        }
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
        log("  → status=waiting reason=awaitingReply (failure)")
    }
}
