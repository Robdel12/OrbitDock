import Foundation

// MARK: - Shared Utilities

enum CLIError: Error, LocalizedError {
    case invalidInput(String)
    case databaseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let msg): return "Invalid input: \(msg)"
        case .databaseError(let msg): return "Database error: \(msg)"
        }
    }
}

/// Read JSON input from stdin
func readInput<T: Decodable>(_ type: T.Type) throws -> T {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else {
        throw CLIError.invalidInput("No input received")
    }

    let decoder = JSONDecoder()
    return try decoder.decode(type, from: data)
}

/// Get terminal session ID from environment
func getTerminalSessionId() -> String? {
    ProcessInfo.processInfo.environment["ITERM_SESSION_ID"]
}

/// Get terminal app from environment
func getTerminalApp() -> String? {
    ProcessInfo.processInfo.environment["TERM_PROGRAM"]
}

/// Log to file (for debugging)
func log(_ message: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let logPath = "\(home)/.orbitdock/cli.log"

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(timestamp)] \(message)\n"

    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}
