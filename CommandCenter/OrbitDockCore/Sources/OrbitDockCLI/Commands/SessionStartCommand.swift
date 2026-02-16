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

    log(
      "[SessionStart] source=\(input.source ?? "unknown") model=\(input.model ?? "unknown") session=\(input.session_id.prefix(8))"
    )
    try sendServerClientMessage(
      type: "claude_session_start",
      fields: [
        "session_id": input.session_id,
        "cwd": input.cwd,
        "model": input.model,
        "source": input.source,
        "context_label": input.context_label,
        "transcript_path": input.transcript_path,
        "permission_mode": input.permission_mode,
        "agent_type": input.agent_type,
        "terminal_session_id": getTerminalSessionId(),
        "terminal_app": getTerminalApp(),
      ]
    )
  }
}
