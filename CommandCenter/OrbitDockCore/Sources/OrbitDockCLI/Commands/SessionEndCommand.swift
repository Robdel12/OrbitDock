import ArgumentParser
import Foundation
import OrbitDockCore

struct SessionEndCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "session-end",
    abstract: "Handle SessionEnd hook from Claude Code"
  )

  func run() throws {
    let input = try readInput(SessionEndInput.self)

    guard !input.session_id.isEmpty else {
      throw CLIError.invalidInput("Missing session_id")
    }

    try sendServerClientMessage(
      type: "claude_session_end",
      fields: [
        "session_id": input.session_id,
        "reason": input.reason,
      ]
    )
  }
}
