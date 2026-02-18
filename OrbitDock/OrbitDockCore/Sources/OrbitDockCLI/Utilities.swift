import Foundation

// MARK: - Shared Utilities

enum CLIError: Error, LocalizedError {
  case invalidInput(String)
  case databaseError(String)
  case transportError(String)

  var errorDescription: String? {
    switch self {
      case let .invalidInput(msg): "Invalid input: \(msg)"
      case let .databaseError(msg): "Database error: \(msg)"
      case let .transportError(msg): "Transport error: \(msg)"
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

private func serverWebSocketURL() -> URL {
  if let raw = ProcessInfo.processInfo.environment["ORBITDOCK_SERVER_WS_URL"],
     let url = URL(string: raw)
  {
    return url
  }
  return URL(string: "ws://127.0.0.1:4000/ws")!
}

private func sendWebSocketPayload(_ payload: [String: Any]) async throws {
  let data = try JSONSerialization.data(withJSONObject: payload)
  guard let json = String(data: data, encoding: .utf8) else {
    throw CLIError.transportError("Failed to encode payload as UTF-8 JSON")
  }

  let task = URLSession.shared.webSocketTask(with: serverWebSocketURL())
  task.resume()
  defer { task.cancel(with: .goingAway, reason: nil) }

  do {
    try await task.send(.string(json))
  } catch {
    throw CLIError.transportError("Failed to send payload to orbitdock-server: \(error.localizedDescription)")
  }
}

func encodeToJSONObject(_ value: some Encodable) -> Any? {
  let encoder = JSONEncoder()
  guard let data = try? encoder.encode(value) else { return nil }
  return try? JSONSerialization.jsonObject(with: data)
}

func sendServerClientMessage(type: String, fields: [String: Any?]) throws {
  var payload: [String: Any] = ["type": type]
  for (key, value) in fields {
    if let value {
      payload[key] = value
    }
  }

  let semaphore = DispatchSemaphore(value: 0)
  var sendError: Error?

  Task {
    do {
      try await sendWebSocketPayload(payload)
    } catch {
      sendError = error
    }
    semaphore.signal()
  }

  let waitResult = semaphore.wait(timeout: .now() + 5)
  if waitResult == .timedOut {
    throw CLIError.transportError("Timed out sending payload to orbitdock-server")
  }
  if let sendError {
    throw sendError
  }
}
