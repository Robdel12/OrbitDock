//
//  ServerManager.swift
//  OrbitDock
//
//  Manages the embedded Rust server process lifecycle.
//  Spawns on app launch, monitors health, restarts on crash.
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "server-manager")

/// Manages the embedded orbitdock-server process
@MainActor
final class ServerManager: ObservableObject {
  static let shared = ServerManager()

  @Published private(set) var isRunning = false
  @Published private(set) var lastError: String?

  private var serverProcess: Process?
  private var healthCheckTask: Task<Void, Never>?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?

  private let serverPort = 4000
  private let healthCheckInterval: TimeInterval = 5.0
  private let maxRestartAttempts = 3
  private var restartAttempts = 0

  private init() {}

  // MARK: - Lifecycle

  /// Start the server process
  func start() {
    guard !isRunning else {
      logger.debug("Server already running")
      return
    }

    lastError = nil

    // Find the server binary
    guard let serverPath = findServerBinary() else {
      lastError = "Server binary not found"
      logger.error("Could not find orbitdock-server binary")
      return
    }

    logger.info("Starting server from: \(serverPath)")

    do {
      try launchServer(at: serverPath)
      isRunning = true
      restartAttempts = 0
      startHealthCheck()
      logger.info("Server started successfully")
    } catch {
      lastError = error.localizedDescription
      logger.error("Failed to start server: \(error.localizedDescription)")
    }
  }

  /// Stop the server process
  func stop() {
    healthCheckTask?.cancel()
    healthCheckTask = nil

    if let process = serverProcess, process.isRunning {
      logger.info("Stopping server...")
      process.terminate()
      serverProcess = nil
    }

    isRunning = false
  }

  /// Restart the server
  func restart() {
    stop()
    start()
  }

  // MARK: - Private

  private func findServerBinary() -> String? {
    // 1. Check app bundle (production)
    if let bundlePath = Bundle.main.path(forResource: "orbitdock-server", ofType: nil) {
      return bundlePath
    }

    // 2. Check Resources folder in bundle
    if let resourcePath = Bundle.main.resourcePath {
      let path = (resourcePath as NSString).appendingPathComponent("orbitdock-server")
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    // 3. Development paths - try repo location
    let homeDir = FileManager.default.homeDirectoryForCurrentUser

    // Try release binary
    let repoPath = homeDir
      .appendingPathComponent("Developer/claude-dashboard/orbitdock-server/target/release/orbitdock-server")
      .path

    if FileManager.default.fileExists(atPath: repoPath) {
      return repoPath
    }

    // Try universal binary
    let universalPath = homeDir
      .appendingPathComponent("Developer/claude-dashboard/orbitdock-server/target/universal/orbitdock-server")
      .path

    if FileManager.default.fileExists(atPath: universalPath) {
      return universalPath
    }

    // 4. Check PATH (fallback)
    let pathDirs = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
    for dir in pathDirs {
      let path = "\(dir)/orbitdock-server"
      if FileManager.default.fileExists(atPath: path) {
        return path
      }
    }

    return nil
  }

  private func launchServer(at path: String) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = []

    // Set up environment
    var env = ProcessInfo.processInfo.environment
    env["RUST_LOG"] = "info"
    process.environment = env

    // Capture output for logging
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe

    // Handle process termination
    process.terminationHandler = { [weak self] process in
      Task { @MainActor in
        self?.handleTermination(exitCode: process.terminationStatus)
      }
    }

    // Read output in background (nonisolated)
    let outputHandle = outputPipe.fileHandleForReading
    let errorHandle = errorPipe.fileHandleForReading

    Task.detached {
      Self.readPipe(handle: outputHandle, label: "stdout")
    }

    Task.detached {
      Self.readPipe(handle: errorHandle, label: "stderr")
    }

    try process.run()
    serverProcess = process

    // Wait a moment for startup
    Thread.sleep(forTimeInterval: 0.5)
  }

  private func handleTermination(exitCode: Int32) {
    logger.warning("Server terminated with exit code: \(exitCode)")
    isRunning = false
    serverProcess = nil

    // Attempt restart if unexpected termination
    if exitCode != 0 && restartAttempts < maxRestartAttempts {
      restartAttempts += 1
      logger.info("Attempting restart (\(self.restartAttempts)/\(self.maxRestartAttempts))...")

      Task {
        try? await Task.sleep(for: .seconds(1))
        await MainActor.run {
          self.start()
        }
      }
    } else if restartAttempts >= maxRestartAttempts {
      lastError = "Server crashed repeatedly, giving up"
      logger.error("Max restart attempts reached")
    }
  }

  /// Read from pipe in background (nonisolated)
  private nonisolated static func readPipe(handle: FileHandle, label: String) {
    while true {
      let data = handle.availableData
      guard !data.isEmpty else { break }
      if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
        logger.debug("[\(label)] \(line)")
      }
    }
  }

  // MARK: - Health Check

  private func startHealthCheck() {
    healthCheckTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(healthCheckInterval))

        guard !Task.isCancelled else { break }

        let healthy = await checkHealth()
        if !healthy && isRunning {
          logger.warning("Health check failed, server may have crashed")
        }
      }
    }
  }

  private func checkHealth() async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else {
      return false
    }

    do {
      let (_, response) = try await URLSession.shared.data(from: url)
      if let httpResponse = response as? HTTPURLResponse {
        return httpResponse.statusCode == 200
      }
      return false
    } catch {
      return false
    }
  }

  /// Wait for server to be ready (for startup sequencing)
  func waitForReady(timeout: TimeInterval = 10) async -> Bool {
    let startTime = Date()

    while Date().timeIntervalSince(startTime) < timeout {
      if await checkHealth() {
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }

    return false
  }
}
