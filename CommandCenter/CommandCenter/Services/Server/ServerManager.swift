//
//  ServerManager.swift
//  OrbitDock
//
//  Manages the embedded Rust server process lifecycle.
//  Spawns on app launch, restarts on crash (with limits).
//  NO continuous polling - uses process termination handler only.
//

import Combine
import Foundation
import os.log

/// Manages the embedded orbitdock-server process
@MainActor
final class ServerManager: ObservableObject {
  static let shared = ServerManager()
  private let logger = Logger(subsystem: "com.orbitdock", category: "server-manager")

  @Published private(set) var isRunning = false
  @Published private(set) var lastError: String?
  @Published private(set) var gaveUp = false // True if we stopped trying

  private var serverProcess: Process?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?

  private let serverPort = 4_000
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
    gaveUp = false

    // Kill any zombie processes on our port first
    killExistingServer()

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
      // NOTE: Don't reset restartAttempts here - only reset when we confirm server is healthy
      // Otherwise the crash -> restart -> crash loop never hits max attempts
      logger.info("Server started successfully")
    } catch {
      lastError = error.localizedDescription
      logger.error("Failed to start server: \(error.localizedDescription)")
    }
  }

  /// Stop the server process
  func stop() {
    // Stop our tracked process
    if let process = serverProcess, process.isRunning {
      logger.info("Stopping server...")
      process.terminate()
      process.waitUntilExit() // Wait for clean shutdown
    }
    serverProcess = nil

    // Also kill any other processes on our port (handles zombies from previous runs)
    killExistingServer()

    isRunning = false
    restartAttempts = 0 // Reset counter when explicitly stopped
  }

  /// Restart the server (resets restart counter)
  func restart() {
    restartAttempts = 0
    gaveUp = false
    stop()
    start()
  }

  /// Kill any existing process on our server port
  private func killExistingServer() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    process.arguments = ["-f", "orbitdock-server"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
      // Give the port time to be released
      if process.terminationStatus == 0 {
        Thread.sleep(forTimeInterval: 0.5)
        logger.info("Killed existing orbitdock-server process")
      }
    } catch {
      // Ignore - no process to kill
    }
  }

  // MARK: - Private

  private func findServerBinary() -> String? {
    // Development paths - prefer local Rust build in DEBUG so rebuilds are always picked up.
    let homeDir = FileManager.default.homeDirectoryForCurrentUser
    let repoBase = homeDir.appendingPathComponent("Developer/claude-dashboard/orbitdock-server/target")
    let debugPath = repoBase.appendingPathComponent("debug/orbitdock-server").path
    let releasePath = repoBase.appendingPathComponent("release/orbitdock-server").path
    let universalPath = repoBase.appendingPathComponent("universal/orbitdock-server").path

    #if DEBUG
      if FileManager.default.fileExists(atPath: debugPath) {
        return debugPath
      }
      if FileManager.default.fileExists(atPath: releasePath) {
        return releasePath
      }
      if FileManager.default.fileExists(atPath: universalPath) {
        return universalPath
      }
    #endif

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
    // Try debug binary first (faster builds during development)
    if FileManager.default.fileExists(atPath: debugPath) {
      return debugPath
    }

    // Try release binary
    if FileManager.default.fileExists(atPath: releasePath) {
      return releasePath
    }

    // Try universal binary
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
    let runId = UUID().uuidString.lowercased()

    // Set up environment with user's full login shell PATH
    var env = ProcessInfo.processInfo.environment
    env["RUST_LOG"] = "debug,tower_http=info,hyper=info"
    env["ORBITDOCK_SERVER_RUN_ID"] = runId
    env["ORBITDOCK_SERVER_BINARY_PATH"] = path
    #if DEBUG
      env["ORBITDOCK_TRUNCATE_SERVER_LOG_ON_START"] = "1"
    #endif
    if let shellPath = Self.resolveLoginShellPath() {
      env["PATH"] = shellPath
    }
    process.environment = env

    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
       let mtime = attrs[.modificationDate] as? Date
    {
      logger.info("Server launch runId=\(runId) binary=\(path) mtime=\(mtime.ISO8601Format())")
    } else {
      logger.info("Server launch runId=\(runId) binary=\(path)")
    }

    // Capture output for logging
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    self.outputPipe = outputPipe
    self.errorPipe = errorPipe

    // Handle process termination
    process.terminationHandler = { [weak self] terminatedProcess in
      let exitCode = terminatedProcess.terminationStatus
      Task { @MainActor [weak self] in
        self?.handleTermination(exitCode: exitCode)
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

    // Exit code 0 = clean shutdown (we called stop()), don't restart
    guard exitCode != 0 else {
      logger.info("Server stopped cleanly")
      return
    }

    // Already gave up - don't try again
    guard !gaveUp else {
      logger.debug("Already gave up, not restarting")
      return
    }

    // Check restart limit
    guard restartAttempts < maxRestartAttempts else {
      lastError = "Server crashed repeatedly, giving up"
      gaveUp = true
      logger.error("Max restart attempts reached (\(self.maxRestartAttempts)) - not retrying")
      return
    }

    // Attempt restart with exponential backoff
    restartAttempts += 1
    logger.info("Attempting restart (\(self.restartAttempts)/\(self.maxRestartAttempts))...")

    // Exponential backoff: 1s, 2s, 4s
    let delay = pow(2.0, Double(restartAttempts - 1))

    Task {
      try? await Task.sleep(for: .seconds(delay))
      await MainActor.run {
        guard !self.gaveUp else { return } // Double-check we haven't given up
        self.start()
      }
    }
  }

  /// Read from pipe in background (nonisolated)
  private nonisolated static func readPipe(handle: FileHandle, label: String) {
    let logger = Logger(subsystem: "com.orbitdock", category: "server-manager")
    while true {
      let data = handle.availableData
      guard !data.isEmpty else { break }
      if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         !line.isEmpty
      {
        logger.debug("[\(label)] \(line)")
      }
    }
  }

  // MARK: - Health Check (one-shot, not polling)

  /// URLSession with short timeout for health checks
  private lazy var healthCheckSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 2
    config.timeoutIntervalForResource = 2
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  private func checkHealth() async -> Bool {
    guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else {
      return false
    }

    do {
      let (_, response) = try await healthCheckSession.data(from: url)
      if let httpResponse = response as? HTTPURLResponse {
        return httpResponse.statusCode == 200
      }
      return false
    } catch {
      return false
    }
  }

  /// Wait for server to be ready (called once at startup, not continuously).
  /// Uses a short warm-up delay and exponential backoff to reduce startup noise.
  func waitForReady(maxAttempts: Int = 10, initialDelayMs: Int = 700) async -> Bool {
    if initialDelayMs > 0 {
      logger.info("Server warming up, retrying health checks...")
      try? await Task.sleep(for: .milliseconds(initialDelayMs))
    }

    for attempt in 1 ... maxAttempts {
      if await checkHealth() {
        // Server is healthy - reset restart counter
        restartAttempts = 0
        gaveUp = false
        logger.info("Server is healthy")
        return true
      }

      if attempt < maxAttempts {
        // Exponential backoff: 250ms, 500ms, 1s, 2s (capped)
        let backoffMs = min(250 * Int(pow(2.0, Double(attempt - 1))), 2_000)
        try? await Task.sleep(for: .milliseconds(backoffMs))
      }
    }

    logger.warning("Server not ready after \(maxAttempts) attempts")
    return false
  }

  /// Reset restart counter (call this to allow retries after user intervention)
  func resetRestartCounter() {
    restartAttempts = 0
    gaveUp = false
  }

  /// Resolve the user's full PATH from their login shell
  /// macOS GUI apps have a minimal PATH that misses nvm, homebrew, etc.
  private nonisolated static func resolveLoginShellPath() -> String? {
    let logger = Logger(subsystem: "com.orbitdock", category: "server-manager")
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: shell)
    proc.arguments = ["-i", "-l", "-c", "echo $PATH"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    do {
      try proc.run()
      proc.waitUntilExit()
      guard proc.terminationStatus == 0 else { return nil }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      if let path, !path.isEmpty {
        logger.debug("Resolved login shell PATH: \(path.prefix(100))...")
        return path
      }
    } catch {
      logger.warning("Failed to resolve login shell PATH: \(error.localizedDescription)")
    }

    return nil
  }
}
