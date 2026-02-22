//
//  ConnectionFileLogger.swift
//  OrbitDock
//
//  Structured file logging for WebSocket connection debugging.
//  Outputs JSON for easy parsing with jq.
//
//  Usage:
//    tail -f ~/.orbitdock/logs/connection.log | jq .
//    tail -f ~/.orbitdock/logs/connection.log | jq 'select(.level == "error")'
//    tail -f ~/.orbitdock/logs/connection.log | jq 'select(.category == "send")'
//

import Foundation

final class ConnectionFileLogger: @unchecked Sendable {
  static let shared = ConnectionFileLogger()

  enum Level: String {
    case debug
    case info
    case warning
    case error
  }

  enum Category: String {
    case lifecycle // connect, disconnect, reconnect
    case send // outgoing WebSocket messages
    case receive // incoming WebSocket messages
    case resume // resume/takeover operations
    case error // errors
  }

  private let fileHandle: FileHandle?
  private let queue = DispatchQueue(label: "com.orbitdock.connection-logger", qos: .utility)
  private let dateFormatter: ISO8601DateFormatter

  private init() {
    let logDirURL = PlatformPaths.orbitDockLogsDirectory
    let logPath = logDirURL.appendingPathComponent("connection.log").path

    dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    try? FileManager.default.createDirectory(at: logDirURL, withIntermediateDirectories: true)

    // Rotate if > 10MB
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? Int,
       size > 10_000_000
    {
      let rotated = logPath + ".1"
      try? FileManager.default.removeItem(atPath: rotated)
      try? FileManager.default.moveItem(atPath: logPath, toPath: rotated)
    }

    FileManager.default.createFile(atPath: logPath, contents: nil)
    fileHandle = FileHandle(forWritingAtPath: logPath)
    fileHandle?.seekToEndOfFile()

    log(
      .info,
      category: .lifecycle,
      message: "=== Connection Logger Started ===",
      data: ["pid": ProcessInfo.processInfo.processIdentifier]
    )
  }

  deinit {
    try? fileHandle?.close()
  }

  nonisolated func log(
    _ level: Level,
    category: Category,
    message: String,
    sessionId: String? = nil,
    data: [String: Any]? = nil
  ) {
    queue.async { [weak self] in
      self?.writeLog(
        level: level,
        category: category,
        message: message,
        sessionId: sessionId,
        data: data
      )
    }
  }

  private func writeLog(
    level: Level,
    category: Category,
    message: String,
    sessionId: String?,
    data: [String: Any]?
  ) {
    var entry: [String: Any] = [
      "ts": dateFormatter.string(from: Date()),
      "level": level.rawValue,
      "category": category.rawValue,
      "message": message,
    ]
    if let sessionId { entry["sessionId"] = sessionId }
    if let data { entry["data"] = data }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: entry, options: []),
          let jsonString = String(data: jsonData, encoding: .utf8)
    else { return }

    let line = jsonString + "\n"
    if let lineData = line.data(using: .utf8) {
      fileHandle?.write(lineData)
    }
  }
}

/// Global shortcut
func connLog(
  _ level: ConnectionFileLogger.Level,
  category: ConnectionFileLogger.Category,
  _ message: String,
  sessionId: String? = nil,
  data: [String: Any]? = nil
) {
  ConnectionFileLogger.shared.log(
    level,
    category: category,
    message: message,
    sessionId: sessionId,
    data: data
  )
}
