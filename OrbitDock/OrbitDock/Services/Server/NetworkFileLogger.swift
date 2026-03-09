//
//  NetworkFileLogger.swift
//  OrbitDock
//
//  Structured file logging for the networking layer (APIClient, EventStream,
//  SessionStore, ConversationStore).
//
//  Outputs JSON-per-line for easy parsing with jq:
//    tail -f ~/.orbitdock/logs/network.log | jq .
//    tail -f ~/.orbitdock/logs/network.log | jq 'select(.level == "error")'
//    tail -f ~/.orbitdock/logs/network.log | jq 'select(.cat == "api")'
//    tail -f ~/.orbitdock/logs/network.log | jq 'select(.cat == "ws")'
//    tail -f ~/.orbitdock/logs/network.log | jq 'select(.sid == "od-abc123")'
//

import Foundation

final class NetworkFileLogger: @unchecked Sendable {
  static let shared = NetworkFileLogger()

  enum Level: String {
    case debug, info, warning, error
  }

  /// Source component that produced the log entry.
  enum Category: String {
    case api   // APIClient HTTP requests
    case ws    // EventStream WebSocket
    case store // SessionStore event routing & actions
    case conv  // ConversationStore loading pipeline
  }

  private let fileHandle: FileHandle?
  private let queue = DispatchQueue(label: "com.orbitdock.network-logger", qos: .utility)
  private let dateFormatter: ISO8601DateFormatter

  private init() {
    let logDir = PlatformPaths.orbitDockLogsDirectory
    let logPath = logDir.appendingPathComponent("network.log").path

    dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

    // Rotate if > 20MB
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
       let size = attrs[.size] as? Int,
       size > 20_000_000
    {
      let rotated = logPath + ".1"
      try? FileManager.default.removeItem(atPath: rotated)
      try? FileManager.default.moveItem(atPath: logPath, toPath: rotated)
    }

    FileManager.default.createFile(
      atPath: logPath, contents: nil,
      attributes: [.posixPermissions: 0o600]
    )
    fileHandle = FileHandle(forWritingAtPath: logPath)
    fileHandle?.seekToEndOfFile()

    log(.info, cat: .store, "=== NetworkFileLogger started pid=\(ProcessInfo.processInfo.processIdentifier) ===")
  }

  deinit {
    try? fileHandle?.close()
  }

  nonisolated func log(
    _ level: Level,
    cat: Category,
    _ message: String,
    sid: String? = nil,
    data: [String: Any]? = nil
  ) {
    queue.async { [weak self] in
      self?.write(level: level, cat: cat, message: message, sid: sid, data: data)
    }
  }

  private func write(
    level: Level, cat: Category, message: String,
    sid: String?, data: [String: Any]?
  ) {
    var entry: [String: Any] = [
      "ts": dateFormatter.string(from: Date()),
      "level": level.rawValue,
      "cat": cat.rawValue,
      "msg": message,
    ]
    if let sid { entry["sid"] = sid }
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

/// Global shortcut — keeps callsites concise.
func netLog(
  _ level: NetworkFileLogger.Level,
  cat: NetworkFileLogger.Category,
  _ message: String,
  sid: String? = nil,
  data: [String: Any]? = nil
) {
  NetworkFileLogger.shared.log(level, cat: cat, message, sid: sid, data: data)
}
