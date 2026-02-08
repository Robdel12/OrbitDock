import ArgumentParser
import Foundation
import OrbitDockCore

struct StatusTrackerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status-tracker",
        abstract: "Handle status events (UserPromptSubmit, Stop, Notification, PreCompact)"
    )

    func run() throws {
        let input = try readInput(StatusTrackerInput.self)

        guard !input.session_id.isEmpty else {
            throw CLIError.invalidInput("Missing session_id")
        }

        let eventInfo = input.notification_type.map { "\(input.hook_event_name):\($0)" } ?? input.hook_event_name
        log("[\(eventInfo)] session=\(input.session_id.prefix(8))")

        let db = try CLIDatabase()
        if let session = db.getSession(id: input.session_id), session.provider == "codex" {
            log("  → skipping status update for codex session")
            return
        }

        switch input.hook_event_name {
        case "UserPromptSubmit":
            try handlePromptSubmit(db: db, sessionId: input.session_id, prompt: input.prompt)

        case "Stop":
            try handleStop(db: db, sessionId: input.session_id, stopHookActive: input.stop_hook_active)

        case "Notification":
            try handleNotification(
                db: db,
                sessionId: input.session_id,
                notificationType: input.notification_type,
                toolName: input.tool_name,
                message: input.message,
                title: input.title
            )

        case "PreCompact":
            try handlePreCompact(
                db: db,
                sessionId: input.session_id,
                trigger: input.trigger,
                customInstructions: input.custom_instructions
            )

        default:
            // Unknown event, ignore
            break
        }

        // Notify the app
        db.notifyApp()
    }

    /// Handle UserPromptSubmit - user sent a message, Claude is working
    private func handlePromptSubmit(db: CLIDatabase, sessionId: String, prompt: String?) throws {
        try db.incrementPromptCount(id: sessionId)
        try db.updateSession(
            id: sessionId,
            workStatus: "working",
            attentionReason: "none",
            firstPrompt: prompt  // Store first prompt for session naming
        )
        try db.clearPendingFields(id: sessionId)
        log("  → status=working reason=none")
    }

    /// Handle Stop - Claude finished processing, waiting for user
    private func handleStop(db: CLIDatabase, sessionId: String, stopHookActive: Bool?) throws {
        // Log if we're in a stop hook loop (useful for debugging)
        if stopHookActive == true {
            log("  ⚠️ stop_hook_active=true (in hook loop)")
        }

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
        log("  → status=waiting reason=\(attentionReason) lastTool=\(lastTool ?? "nil")")
    }

    /// Handle Notification - idle_prompt, permission_prompt, auth_success, elicitation_dialog
    private func handleNotification(
        db: CLIDatabase,
        sessionId: String,
        notificationType: String?,
        toolName: String?,
        message: String?,
        title: String?
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
            log("  → status=waiting reason=\(attentionReason)")

        case "permission_prompt":
            // Claude needs permission for a tool
            try db.updateSession(
                id: sessionId,
                workStatus: "permission",
                attentionReason: "awaitingPermission"
            )
            log("  → status=permission reason=awaitingPermission")

        case "auth_success":
            // Authentication succeeded - just log it
            log("  → auth_success: \(message ?? "")")

        case "elicitation_dialog":
            // Claude is asking user to choose - similar to question
            try db.updateSession(
                id: sessionId,
                workStatus: "waiting",
                attentionReason: "awaitingQuestion"
            )
            log("  → status=waiting reason=awaitingQuestion (elicitation)")

        default:
            if let nt = notificationType {
                log("  → unhandled notification_type: \(nt)")
            }
        }
    }

    /// Handle PreCompact - context is about to be compacted
    private func handlePreCompact(
        db: CLIDatabase,
        sessionId: String,
        trigger: String?,
        customInstructions: String?
    ) throws {
        // Record the compaction event
        try db.recordCompaction(
            sessionId: sessionId,
            trigger: trigger ?? "unknown",
            customInstructions: customInstructions
        )

        // Increment compact count on session
        try db.incrementCompactCount(id: sessionId)

        log("  → compact trigger=\(trigger ?? "unknown")")
    }
}
