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
        try sendServerClientMessage(
            type: "claude_status_event",
            fields: [
                "session_id": input.session_id,
                "cwd": input.cwd,
                "transcript_path": input.transcript_path,
                "hook_event_name": input.hook_event_name,
                "notification_type": input.notification_type,
                "tool_name": input.tool_name,
                "stop_hook_active": input.stop_hook_active,
                "prompt": input.prompt,
                "message": input.message,
                "title": input.title,
                "trigger": input.trigger,
                "custom_instructions": input.custom_instructions,
            ]
        )
    }
}
