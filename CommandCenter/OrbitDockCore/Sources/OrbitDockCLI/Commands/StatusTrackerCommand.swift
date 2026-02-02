import ArgumentParser
import Foundation
import OrbitDockCore

struct StatusTrackerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-tracker",
        abstract: "Handle status events (UserPromptSubmit, Stop, Notification)"
    )

    func run() throws {
        let input = try readInput(StatusTrackerInput.self)

        guard !input.session_id.isEmpty else {
            throw CLIError.invalidInput("Missing session_id")
        }

        let db = try CLIDatabase()

        switch input.hook_event_name {
        case "UserPromptSubmit":
            try handlePromptSubmit(db: db, sessionId: input.session_id)

        case "Stop":
            try handleStop(db: db, sessionId: input.session_id)

        case "Notification":
            try handleNotification(
                db: db,
                sessionId: input.session_id,
                notificationType: input.notification_type,
                toolName: input.tool_name
            )

        default:
            // Unknown event, ignore
            break
        }

        // Notify the app
        db.notifyApp()
    }

    /// Handle UserPromptSubmit - user sent a message, Claude is working
    private func handlePromptSubmit(db: CLIDatabase, sessionId: String) throws {
        try db.incrementPromptCount(id: sessionId)
        try db.updateSession(
            id: sessionId,
            workStatus: "working",
            attentionReason: "none"
        )
        try db.clearPendingFields(id: sessionId)
    }

    /// Handle Stop - Claude finished processing, waiting for user
    private func handleStop(db: CLIDatabase, sessionId: String) throws {
        // Get the session to check last tool
        let session = db.getSession(id: sessionId)
        let lastTool = session?.lastTool

        // Determine attention reason based on last tool
        let attentionReason: String
        if lastTool == "AskUserQuestion" {
            attentionReason = "awaitingQuestion"
        } else {
            attentionReason = "awaitingReply"
        }

        try db.updateSession(
            id: sessionId,
            workStatus: "waiting",
            attentionReason: attentionReason
        )
    }

    /// Handle Notification - idle_prompt or permission_prompt
    private func handleNotification(
        db: CLIDatabase,
        sessionId: String,
        notificationType: String?,
        toolName: String?
    ) throws {
        switch notificationType {
        case "idle_prompt":
            // Claude is waiting for user input
            let session = db.getSession(id: sessionId)
            let lastTool = session?.lastTool

            let attentionReason: String
            if lastTool == "AskUserQuestion" {
                attentionReason = "awaitingQuestion"
            } else {
                attentionReason = "awaitingReply"
            }

            try db.updateSession(
                id: sessionId,
                workStatus: "waiting",
                attentionReason: attentionReason
            )

        case "permission_prompt":
            // Claude needs permission for a tool
            try db.updateSession(
                id: sessionId,
                workStatus: "permission",
                attentionReason: "awaitingPermission"
            )

        default:
            break
        }
    }
}
