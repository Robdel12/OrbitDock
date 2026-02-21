//
//  TimelineFileLogger.swift
//  OrbitDock
//
//  Lightweight file logger for conversation timeline debugging.
//  macOS: ~/.orbitdock/logs/timeline.log
//  iOS:   ~/.orbitdock/logs/timeline-ios.log
//

import SwiftUI

final class TimelineFileLogger: @unchecked Sendable {
  static let shared = TimelineFileLogger()

  private let fileHandle: FileHandle?
  private let queue = DispatchQueue(label: "com.orbitdock.timeline-logger", qos: .utility)
  private let dateFormatter: DateFormatter

  private init() {
    let logDir = PlatformPaths.orbitDockLogsDirectory
    #if os(iOS)
      let logPath = logDir.appendingPathComponent("timeline-ios.log").path
    #else
      let logPath = logDir.appendingPathComponent("timeline.log").path
    #endif

    dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss.SSS"

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
    let msg = message()
    queue.async { [weak self] in
      self?.write(msg)
    }
  }

  nonisolated func info(_ message: @autoclosure () -> String) {
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
