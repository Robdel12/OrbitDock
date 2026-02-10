//
//  AppFileLogger.swift
//  OrbitDock
//
//  Captures app stdout/stderr to ~/.orbitdock/logs/app.log
//  so runtime diagnostics are available outside Xcode.
//

import Darwin
import Foundation

final class AppFileLogger: @unchecked Sendable {
  nonisolated(unsafe) static let shared = AppFileLogger()

  private var redirected = false

  private init() {}

  func start() {
    guard !redirected else { return }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let logDir = home.appendingPathComponent(".orbitdock/logs")
    let logPath = logDir.appendingPathComponent("app.log").path

    do {
      try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    } catch {
      return
    }

    #if DEBUG
      let debugDefaultTruncate = true
    #else
      let debugDefaultTruncate = false
    #endif
    let shouldTruncate = ProcessInfo.processInfo
      .environment["ORBITDOCK_TRUNCATE_APP_LOG_ON_START"] == "1" || debugDefaultTruncate
    let flags = O_WRONLY | O_CREAT | (shouldTruncate ? O_TRUNC : O_APPEND)
    let fd = open(logPath, flags, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
    guard fd >= 0 else { return }

    // Route both stdout and stderr to app.log for consistent diagnostics capture.
    if dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0 {
      close(fd)
      return
    }
    close(fd)

    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IOLBF, 0)

    redirected = true
    print("=== OrbitDock app logger started pid=\(ProcessInfo.processInfo.processIdentifier) ===")
  }
}
