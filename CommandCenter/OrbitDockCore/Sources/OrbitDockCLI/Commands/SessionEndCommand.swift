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

        let db = try CLIDatabase()

        // End the session
        try db.endSession(id: input.session_id, reason: input.reason)

        // Notify the app
        db.notifyApp()
    }
}
