//
//  TimelineFileLogger.swift
//  OrbitDock
//
//  Lightweight file logger for conversation timeline debugging.
//  macOS: ~/.orbitdock/logs/timeline.log
//  iOS:   ~/.orbitdock/logs/timeline-ios.log
//  Enable with ORBITDOCK_TIMELINE_LOG=1 or UserDefaults key ORBITDOCK_TIMELINE_LOG=true.
//

import SwiftUI

final class TimelineFileLogger: @unchecked Sendable {
  static let shared = TimelineFileLogger()

  private let isEnabled: Bool
  private let fileHandle: FileHandle?
  private let queue = DispatchQueue(label: "com.orbitdock.timeline-logger", qos: .utility)
  private let dateFormatter: DateFormatter

  private init() {
    isEnabled = Self.resolveEnabledFlag()

    dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss.SSS"

    guard isEnabled else {
      fileHandle = nil
      return
    }

    let logDir = PlatformPaths.orbitDockLogsDirectory
    #if os(iOS)
      let logPath = logDir.appendingPathComponent("timeline-ios.log").path
    #else
      let logPath = logDir.appendingPathComponent("timeline.log").path
    #endif

    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

    FileManager.default.createFile(atPath: logPath, contents: nil)
    fileHandle = FileHandle(forWritingAtPath: logPath)
    fileHandle?.truncateFile(atOffset: 0)

    write("--- timeline logger started ---")
  }

  deinit {
    try? fileHandle?.close()
  }

  nonisolated func debug(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let msg = message()
    queue.async { [weak self] in
      self?.write(msg)
    }
  }

  nonisolated func info(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    let msg = message()
    queue.async { [weak self] in
      self?.write("ℹ️ \(msg)")
    }
  }

  private func write(_ message: String) {
    let timestamp = dateFormatter.string(from: Date())
    let line = "\(timestamp) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    fileHandle?.seekToEndOfFile()
    fileHandle?.write(data)
  }

  private static func resolveEnabledFlag() -> Bool {
    if let rawValue = ProcessInfo.processInfo.environment["ORBITDOCK_TIMELINE_LOG"] {
      return enabledFlag(from: rawValue)
    }
    if let rawValue = UserDefaults.standard.object(forKey: "ORBITDOCK_TIMELINE_LOG") as? String {
      return enabledFlag(from: rawValue)
    }
    if let boolValue = UserDefaults.standard.object(forKey: "ORBITDOCK_TIMELINE_LOG") as? Bool {
      return boolValue
    }
    return false
  }

  private static func enabledFlag(from rawValue: String) -> Bool {
    switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        true
      default:
        false
    }
  }
}

// MARK: - View Extension for Optional Environment

extension View {
  @ViewBuilder
  func ifLet<T>(_ value: T?, transform: (Self, T) -> some View) -> some View {
    if let value {
      transform(self, value)
    } else {
      self
    }
  }
}
