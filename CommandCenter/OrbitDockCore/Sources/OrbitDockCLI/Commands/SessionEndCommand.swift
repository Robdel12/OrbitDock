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

        // Get session to find linked workstream
        let session = db.getSession(id: input.session_id)

        // End the session
        try db.endSession(id: input.session_id, reason: input.reason)

        // Update workstream activity if linked
        if let wsId = session?.workstreamId {
            try db.updateWorkstreamActivity(id: wsId)
        }

        // Notify the app
        db.notifyApp()
    }
}
