//
//  ServerManager.swift
//  OrbitDock
//
//  Thin CLI wrapper around `orbitdock-server` subcommands.
//  Detects install state, shells out for init/install/start/stop.
//  NO embedded process management — the server runs via launchd or manually.
//

import Combine
import Foundation
import os.log

enum ServerInstallState: Equatable {
  case unknown // Haven't checked yet
  case notConfigured // No server binary found, no remote host
  case running // Health check passes (don't care how it started)
  case installed // Binary + launchd plist exist, but not responding
  case remote // Remote host configured
}

#if os(macOS)
  @MainActor
  final class ServerManager: ObservableObject {
    static let shared = ServerManager()
    private let logger = Logger(subsystem: "com.orbitdock", category: "server-manager")

    @Published private(set) var installState: ServerInstallState = .unknown
    @Published var isInstalling = false
    @Published var installError: String?

    private let serverPort = 4_000
    private let serviceName = "com.orbitdock.server"

    private lazy var healthCheckSession: URLSession = {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 2
      config.timeoutIntervalForResource = 2
      config.waitsForConnectivity = false
      return URLSession(configuration: config)
    }()

    private init() {}

    // MARK: - State Detection

    /// Refresh install state. Priority order:
    /// 1. Health check → .running
    /// 2. Launchd plist exists → .installed (stopped)
    /// 3. Remote host configured → .remote
    /// 4. Otherwise → .notConfigured
    func refreshState() async {
      if await checkHealth() {
        installState = .running
        return
      }

      if launchdPlistExists() {
        installState = .installed
        return
      }

      if ServerEndpointSettings.remoteHost != nil {
        installState = .remote
        return
      }

      installState = .notConfigured
    }

    // MARK: - Binary Discovery

    /// Find the orbitdock-server binary. Checks:
    /// 1. Bundle Resources (bundled with app)
    /// 2. ORBITDOCK_SERVER_PATH env var
    /// 3. ~/.orbitdock/bin/ (installed by us)
    /// 4. PATH (brew, cargo install, etc.)
    func findServerBinary() -> String? {
      // 1. Bundle Resources
      if let bundlePath = Bundle.main.url(forResource: "orbitdock-server", withExtension: nil) {
        if FileManager.default.fileExists(atPath: bundlePath.path) {
          return bundlePath.path
        }
      }

      // 2. Environment override
      if let envPath = ProcessInfo.processInfo.environment["ORBITDOCK_SERVER_PATH"],
         FileManager.default.fileExists(atPath: envPath)
      {
        return envPath
      }

      // 3. Installed location
      let installedPath = PlatformPaths.orbitDockBinDirectory
        .appendingPathComponent("orbitdock-server").path
      if FileManager.default.fileExists(atPath: installedPath) {
        return installedPath
      }

      // 4. Search PATH
      let shellPath = Self.resolveLoginShellPath()
        ?? ProcessInfo.processInfo.environment["PATH"]
        ?? ""
      let pathDirs = shellPath.split(separator: ":")
      for dir in pathDirs {
        let path = "\(dir)/orbitdock-server"
        if FileManager.default.fileExists(atPath: path) {
          return path
        }
      }

      return nil
    }

    // MARK: - Install

    /// Full setup sequence:
    /// 1. Find binary
    /// 2. Copy to ~/.orbitdock/bin/ (if from bundle)
    /// 3. Run `orbitdock-server init`
    /// 4. Run `orbitdock-server install-hooks`
    /// 5. Run `orbitdock-server install-service --enable`
    /// 6. Wait for health check
    /// 7. Refresh state
    func install() async throws {
      isInstalling = true
      installError = nil

      defer { isInstalling = false }

      guard let sourcePath = findServerBinary() else {
        let msg = "Could not find orbitdock-server binary"
        installError = msg
        throw ServerInstallError.binaryNotFound
      }

      // If the binary is from the bundle, copy it to ~/.orbitdock/bin/
      let binaryPath: String
      if sourcePath.contains(".app/Contents/Resources") {
        let binDir = PlatformPaths.orbitDockBinDirectory
        PlatformPaths.ensureDirectory(binDir)
        let destPath = binDir.appendingPathComponent("orbitdock-server").path

        do {
          // Remove existing if present
          if FileManager.default.fileExists(atPath: destPath) {
            try FileManager.default.removeItem(atPath: destPath)
          }
          try FileManager.default.copyItem(atPath: sourcePath, toPath: destPath)

          // Ensure executable
          let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
          try FileManager.default.setAttributes(attrs, ofItemAtPath: destPath)

          logger.info("Copied server binary to \(destPath)")
          binaryPath = destPath
        } catch {
          let msg = "Failed to copy binary: \(error.localizedDescription)"
          installError = msg
          throw ServerInstallError.copyFailed(error)
        }
      } else {
        binaryPath = sourcePath
      }

      // Run init
      do {
        try await runCLI(binaryPath, arguments: ["init"])
        logger.info("orbitdock-server init completed")
      } catch {
        let msg = "init failed: \(error.localizedDescription)"
        installError = msg
        throw error
      }

      // Install hooks
      do {
        try await runCLI(binaryPath, arguments: ["install-hooks"])
        logger.info("orbitdock-server install-hooks completed")
      } catch {
        let msg = "install-hooks failed: \(error.localizedDescription)"
        installError = msg
        throw error
      }

      // Install + enable launchd service
      do {
        try await runCLI(binaryPath, arguments: ["install-service", "--enable"])
        logger.info("orbitdock-server install-service --enable completed")
      } catch {
        let msg = "install-service failed: \(error.localizedDescription)"
        installError = msg
        throw error
      }

      // Wait for server to come up
      let ready = await waitForHealth(maxAttempts: 15)
      if !ready {
        let msg = "Server installed but not responding"
        installError = msg
        throw ServerInstallError.healthCheckFailed
      }

      await refreshState()
      logger.info("Server installation complete")
    }

    // MARK: - Uninstall

    func uninstall() async throws {
      let plistPath = launchdPlistPath()

      // Unload service
      if FileManager.default.fileExists(atPath: plistPath) {
        do {
          try await runShell("/bin/launchctl", arguments: ["unload", plistPath])
        } catch {
          logger.warning("launchctl unload failed (may already be unloaded): \(error.localizedDescription)")
        }

        // Remove plist
        try? FileManager.default.removeItem(atPath: plistPath)
        logger.info("Removed launchd plist")
      }

      await refreshState()
    }

    // MARK: - Service Control

    func startService() async throws {
      try await runShell("/bin/launchctl", arguments: ["start", serviceName])
      // Wait briefly for startup
      let ready = await waitForHealth(maxAttempts: 10)
      if ready {
        installState = .running
      }
    }

    func stopService() async throws {
      try await runShell("/bin/launchctl", arguments: ["stop", serviceName])
      // Give the process time to terminate
      try? await Task.sleep(for: .milliseconds(500))
      await refreshState()
    }

    func restartService() async throws {
      try await stopService()
      try await startService()
    }

    // MARK: - Health Check

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

    /// Wait for server to become healthy with exponential backoff.
    func waitForHealth(maxAttempts: Int = 10) async -> Bool {
      for attempt in 1 ... maxAttempts {
        if await checkHealth() {
          return true
        }
        if attempt < maxAttempts {
          let backoffMs = min(250 * Int(pow(2.0, Double(attempt - 1))), 2_000)
          try? await Task.sleep(for: .milliseconds(backoffMs))
        }
      }
      return false
    }

    // MARK: - Helpers

    private func launchdPlistPath() -> String {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return "\(home)/Library/LaunchAgents/\(serviceName).plist"
    }

    private func launchdPlistExists() -> Bool {
      FileManager.default.fileExists(atPath: launchdPlistPath())
    }

    /// Run the orbitdock-server CLI binary with arguments.
    private func runCLI(_ binaryPath: String, arguments: [String]) async throws {
      try await runShell(binaryPath, arguments: arguments)
    }

    /// Run an arbitrary command, capturing stdout/stderr. Throws on non-zero exit.
    @discardableResult
    private func runShell(_ executablePath: String, arguments: [String]) async throws -> String {
      try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        // Inherit login shell PATH so the server binary can find dependencies
        var env = ProcessInfo.processInfo.environment
        if let shellPath = Self.resolveLoginShellPath() {
          env["PATH"] = shellPath
        }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        process.terminationHandler = { proc in
          let outData = stdout.fileHandleForReading.readDataToEndOfFile()
          let errData = stderr.fileHandleForReading.readDataToEndOfFile()
          let outStr = String(data: outData, encoding: .utf8) ?? ""
          let errStr = String(data: errData, encoding: .utf8) ?? ""

          if proc.terminationStatus == 0 {
            continuation.resume(returning: outStr)
          } else {
            let msg = errStr.isEmpty ? "Exit code \(proc.terminationStatus)" : errStr
              .trimmingCharacters(in: .whitespacesAndNewlines)
            continuation.resume(throwing: ServerInstallError.commandFailed(msg))
          }
        }

        do {
          try process.run()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }

    /// Resolve the user's full PATH from their login shell.
    /// macOS GUI apps have a minimal PATH that misses nvm, homebrew, etc.
    private nonisolated static func resolveLoginShellPath() -> String? {
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
          return path
        }
      } catch {
        // Fall through
      }

      return nil
    }
  }

  // MARK: - Errors

  enum ServerInstallError: LocalizedError {
    case binaryNotFound
    case copyFailed(Error)
    case commandFailed(String)
    case healthCheckFailed

    var errorDescription: String? {
      switch self {
        case .binaryNotFound:
          "Could not find orbitdock-server binary"
        case let .copyFailed(err):
          "Failed to copy binary: \(err.localizedDescription)"
        case let .commandFailed(msg):
          msg
        case .healthCheckFailed:
          "Server installed but not responding to health checks"
      }
    }
  }

#else

  @MainActor
  final class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published private(set) var installState: ServerInstallState = .notConfigured
    @Published var isInstalling = false
    @Published var installError: String?

    private init() {}

    func refreshState() async {
      if ServerEndpointSettings.remoteHost != nil {
        installState = .remote
      } else {
        installState = .notConfigured
      }
    }

    func findServerBinary() -> String? {
      nil
    }
  }

#endif
