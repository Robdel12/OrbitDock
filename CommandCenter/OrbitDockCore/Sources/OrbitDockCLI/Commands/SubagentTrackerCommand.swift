import ArgumentParser
import Foundation
import OrbitDockCore

struct SubagentTrackerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subagent-tracker",
        abstract: "Handle subagent events (SubagentStart, SubagentStop)"
    )

    func run() throws {
        let input = try readInput(SubagentInput.self)

        guard !input.session_id.isEmpty else {
            throw CLIError.invalidInput("Missing session_id")
        }

        let agentType = input.agent_type ?? "unknown"
        log("[\(input.hook_event_name)] agent=\(agentType) id=\(input.agent_id.prefix(8)) session=\(input.session_id.prefix(8))")

        let db = try CLIDatabase()

        switch input.hook_event_name {
        case "SubagentStart":
            try handleSubagentStart(
                db: db,
                sessionId: input.session_id,
                agentId: input.agent_id,
                agentType: agentType
            )

        case "SubagentStop":
            try handleSubagentStop(
                db: db,
                sessionId: input.session_id,
                agentId: input.agent_id,
                agentType: agentType,
                transcriptPath: input.agent_transcript_path
            )

        default:
            break
        }

        // Notify the app
        db.notifyApp()
    }

    /// Handle SubagentStart - a subagent was spawned
    private func handleSubagentStart(
        db: CLIDatabase,
        sessionId: String,
        agentId: String,
        agentType: String
    ) throws {
        // Create subagent record
        try db.createSubagent(
            id: agentId,
            sessionId: sessionId,
            agentType: agentType
        )

        // Update session with active subagent
        try db.updateSession(
            id: sessionId,
            activeSubagentId: agentId,
            activeSubagentType: agentType
        )

        log("  → subagent started: \(agentType)")
    }

    /// Handle SubagentStop - a subagent finished
    private func handleSubagentStop(
        db: CLIDatabase,
        sessionId: String,
        agentId: String,
        agentType: String,
        transcriptPath: String?
    ) throws {
        // End subagent record
        try db.endSubagent(
            id: agentId,
            transcriptPath: transcriptPath
        )

        // Clear active subagent from session
        try db.clearActiveSubagent(id: sessionId)

        log("  → subagent ended: \(agentType)")
    }
}
