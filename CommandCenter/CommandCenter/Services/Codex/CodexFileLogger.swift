//
//  CodexFileLogger.swift
//  OrbitDock
//
//  Structured file logging for Codex debugging.
//  Outputs JSON for easy parsing with jq, grep, etc.
//
//  Usage:
//    tail -f ~/.orbitdock/logs/codex.log | jq .
//    tail -f ~/.orbitdock/logs/codex.log | jq 'select(.level == "error")'
//    tail -f ~/.orbitdock/logs/codex.log | jq 'select(.category == "event")'
//

import Foundation

/// Centralized file logger for Codex debugging
/// Writes structured JSON logs to ~/.orbitdock/logs/
final class CodexFileLogger: @unchecked Sendable {
  nonisolated(unsafe) static let shared = CodexFileLogger()

  enum Level: String {
    case debug
    case info
    case warning
    case error
  }

  enum Category: String {
    case event       // Codex server events
    case connection  // Connection lifecycle
    case message     // Message store operations
    case bridge      // MCP bridge requests
    case decode      // JSON decode operations
    case session     // Session lifecycle
  }

  private let fileHandle: FileHandle?
  private let logDir: String
  private let logPath: String
  private let queue = DispatchQueue(label: "com.orbitdock.codex-logger", qos: .utility)
  private let dateFormatter: ISO8601DateFormatter

  private init() {
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    logDir = homeDir + "/.orbitdock/logs"
    logPath = logDir + "/codex.log"

    dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    // Create logs directory
    try? FileManager.default.createDirectory(
      atPath: logDir,
      withIntermediateDirectories: true
    )

    // Rotate if log is too large (> 10MB)
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? Int,
       size > 10_000_000
    {
      let rotatedPath = logPath + ".1"
      try? FileManager.default.removeItem(atPath: rotatedPath)
      try? FileManager.default.moveItem(atPath: logPath, toPath: rotatedPath)
    }

    // Create or open log file
    FileManager.default.createFile(atPath: logPath, contents: nil)
    fileHandle = FileHandle(forWritingAtPath: logPath)
    fileHandle?.seekToEndOfFile()

    // Write startup marker
    log(
      .info,
      category: .session,
      message: "=== OrbitDock Codex Logger Started ===",
      data: ["pid": ProcessInfo.processInfo.processIdentifier]
    )
  }

  deinit {
    try? fileHandle?.close()
  }

  // MARK: - Public API

  nonisolated func log(
    _ level: Level,
    category: Category,
    message: String,
    sessionId: String? = nil,
    data: [String: Any]? = nil
  ) {
    queue.async { [weak self] in
      self?.writeLog(level: level, category: category, message: message, sessionId: sessionId, data: data)
    }
  }

  /// Log a raw event with full payload (for debugging)
  nonisolated func logEvent(
    _ eventType: String,
    sessionId: String?,
    payload: [String: Any]
  ) {
    log(.debug, category: .event, message: eventType, sessionId: sessionId, data: payload)
  }

  /// Log a decode error with raw JSON
  nonisolated func logDecodeError(
    _ error: Error,
    rawJson: String,
    context: String
  ) {
    log(
      .error,
      category: .decode,
      message: "Decode failed: \(context)",
      data: [
        "error": String(describing: error),
        "rawJson": String(rawJson.prefix(2000)),  // Truncate long payloads
      ]
    )
  }

  /// Log connection state change
  nonisolated func logConnectionState(
    _ state: String,
    details: String? = nil
  ) {
    var data: [String: Any] = ["state": state]
    if let details {
      data["details"] = details
    }
    log(.info, category: .connection, message: "Connection: \(state)", data: data)
  }

  /// Log MCP bridge request/response
  nonisolated func logBridgeRequest(
    method: String,
    path: String,
    body: [String: Any]?,
    responseStatus: Int?,
    responseBody: [String: Any]?,
    durationMs: Double?
  ) {
    var data: [String: Any] = [
      "method": method,
      "path": path,
    ]
    if let body, !body.isEmpty {
      data["requestBody"] = body
    }
    if let responseStatus {
      data["responseStatus"] = responseStatus
    }
    if let responseBody {
      data["responseBody"] = responseBody
    }
    if let durationMs {
      data["durationMs"] = String(format: "%.2f", durationMs)
    }

    let level: Level = (responseStatus ?? 200) >= 400 ? .warning : .debug
    log(level, category: .bridge, message: "\(method) \(path)", data: data)
  }

  /// Log message store operation
  nonisolated func logMessageOp(
    _ op: String,
    messageId: String,
    sessionId: String,
    details: [String: Any]? = nil
  ) {
    var data: [String: Any] = [
      "op": op,
      "messageId": messageId,
    ]
    if let details {
      data.merge(details) { _, new in new }
    }
    log(.debug, category: .message, message: "\(op): \(messageId)", sessionId: sessionId, data: data)
  }

  // MARK: - Private

  private func writeLog(
    level: Level,
    category: Category,
    message: String,
    sessionId: String?,
    data: [String: Any]?
  ) {
    var logEntry: [String: Any] = [
      "ts": dateFormatter.string(from: Date()),
      "level": level.rawValue,
      "category": category.rawValue,
      "message": message,
    ]

    if let sessionId {
      logEntry["sessionId"] = sessionId
    }

    if let data {
      logEntry["data"] = data
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: logEntry, options: []),
          let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      return
    }

    let line = jsonString + "\n"
    if let lineData = line.data(using: .utf8) {
      fileHandle?.write(lineData)
    }
  }
}

// MARK: - Convenience

/// Global shortcut for logging
func codexLog(
  _ level: CodexFileLogger.Level,
  category: CodexFileLogger.Category,
  _ message: String,
  sessionId: String? = nil,
  data: [String: Any]? = nil
) {
  CodexFileLogger.shared.log(level, category: category, message: message, sessionId: sessionId, data: data)
}
