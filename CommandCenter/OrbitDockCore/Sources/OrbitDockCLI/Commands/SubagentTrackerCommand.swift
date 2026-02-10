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
        try sendServerClientMessage(
            type: "claude_subagent_event",
            fields: [
                "session_id": input.session_id,
                "hook_event_name": input.hook_event_name,
                "agent_id": input.agent_id,
                "agent_type": input.agent_type,
                "agent_transcript_path": input.agent_transcript_path,
            ]
        )

        if input.hook_event_name == "SubagentStart" {
            log("  → subagent started: \(agentType)")
        } else if input.hook_event_name == "SubagentStop" {
            log("  → subagent ended: \(agentType)")
        } else {
            log("  → unhandled subagent event: \(input.hook_event_name)")
        }
    }
}
