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
    try sendServerClientMessage(
      type: "claude_tool_event",
      fields: [
        "session_id": input.session_id,
        "cwd": input.cwd,
        "hook_event_name": input.hook_event_name,
        "tool_name": input.tool_name,
        "tool_input": input.tool_input.flatMap { encodeToJSONObject($0) },
        "tool_response": input.tool_response.flatMap { encodeToJSONObject($0) },
        "tool_use_id": input.tool_use_id,
        "error": input.error,
        "is_interrupt": input.is_interrupt,
      ]
    )

    switch input.hook_event_name {
      case "PreToolUse":
        log("  → status=working lastTool=\(input.tool_name)")
      case "PostToolUse":
        log("  → status=working reason=none")
      case "PostToolUseFailure":
        log("  → status=waiting reason=awaitingReply (failure)")
      default:
        break
    }
  }
}
