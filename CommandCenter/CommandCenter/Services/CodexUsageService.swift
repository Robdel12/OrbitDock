//
//  CodexUsageService.swift
//  OrbitDock
//
//  Fetches Codex/ChatGPT usage via the codex app-server JSON-RPC protocol.
//  Spawns process on-demand, fetches usage, then terminates.
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.orbitdock", category: "CodexUsage")

// MARK: - Models

struct CodexUsage: Sendable {
  struct RateLimit: Sendable {
    let usedPercent: Double
    let windowDurationMins: Int
    let resetsAt: Date

    var remaining: Double { max(0, 100 - usedPercent) }

    var resetsInDescription: String {
      let interval = resetsAt.timeIntervalSinceNow
      if interval <= 0 { return "now" }
      let hours = Int(interval / 3_600)
      let minutes = Int((interval.truncatingRemainder(dividingBy: 3_600)) / 60)
      return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var timeRemaining: TimeInterval { max(0, resetsAt.timeIntervalSinceNow) }
    var windowDuration: TimeInterval { TimeInterval(windowDurationMins * 60) }
    var timeElapsed: TimeInterval { windowDuration - timeRemaining }

    var burnRatePerHour: Double {
      guard timeElapsed > 0 else { return 0 }
      return usedPercent / (timeElapsed / 3_600)
    }

    var projectedAtReset: Double {
      guard timeElapsed > 60 else { return usedPercent }
      let rate = usedPercent / timeElapsed
      return min(100, rate * windowDuration)
    }

    var willExceed: Bool { projectedAtReset > 95 }

    var paceStatus: PaceStatus {
      if timeElapsed < 60 { return .unknown }
      let sustainableRate = 100.0 / (windowDuration / 3_600)
      let ratio = burnRatePerHour / sustainableRate
      if ratio < 0.5 { return .relaxed }
      if ratio < 0.9 { return .onTrack }
      if ratio < 1.1 { return .borderline }
      if ratio < 1.5 { return .exceeding }
      return .critical
    }

    enum PaceStatus: String {
      case unknown = "—"
      case relaxed = "Relaxed"
      case onTrack = "On Track"
      case borderline = "Borderline"
      case exceeding = "Exceeding"
      case critical = "Critical"

      var color: String {
        switch self {
          case .unknown: "secondary"
          case .relaxed: "accent"
          case .onTrack: "statusSuccess"
          case .borderline: "statusWaiting"
          case .exceeding, .critical: "statusError"
        }
      }

      var icon: String {
        switch self {
          case .unknown: "minus"
          case .relaxed: "tortoise.fill"
          case .onTrack: "checkmark.circle.fill"
          case .borderline: "exclamationmark.circle.fill"
          case .exceeding: "flame.fill"
          case .critical: "bolt.fill"
        }
      }
    }
  }

  let primary: RateLimit?
  let secondary: RateLimit?
  let fetchedAt: Date

  /// Convert to unified RateLimitWindow array for generic UI components
  var windows: [RateLimitWindow] {
    var result: [RateLimitWindow] = []
    if let primary {
      result.append(.fromMinutes(
        id: "primary",
        utilization: primary.usedPercent,
        windowMinutes: primary.windowDurationMins,
        resetsAt: primary.resetsAt
      ))
    }
    if let secondary {
      result.append(.fromMinutes(
        id: "secondary",
        utilization: secondary.usedPercent,
        windowMinutes: secondary.windowDurationMins,
        resetsAt: secondary.resetsAt
      ))
    }
    return result
  }
}

enum CodexUsageError: LocalizedError {
  case notInstalled
  case notLoggedIn
  case apiKeyMode
  case requestFailed(String)

  var errorDescription: String? {
    switch self {
      case .notInstalled: "Codex CLI not installed"
      case .notLoggedIn: "Not logged into Codex"
      case .apiKeyMode: "Using API key (no rate limits)"
      case let .requestFailed(msg): msg
    }
  }
}

// MARK: - Service

@Observable
@MainActor
final class CodexUsageService {
  static let shared = CodexUsageService()

  private(set) var usage: CodexUsage?
  private(set) var error: CodexUsageError?
  private(set) var isLoading = false

  private let refreshInterval: TimeInterval = 300 // 5 minutes
  private let staleThreshold: TimeInterval = 600 // 10 minutes
  private let cacheValidDuration: TimeInterval = 180 // 3 minutes - use cached data without fetching
  private var refreshTask: Task<Void, Never>?

  // Disk cache for usage data
  private nonisolated static let cacheURL: URL = {
    let cacheDir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".orbitdock/cache", isDirectory: true)
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    return cacheDir.appendingPathComponent("codex-usage.json")
  }()

  private var isTestMode: Bool {
    ProcessInfo.processInfo.environment["ORBITDOCK_TEST_DB"] != nil
  }

  private init() {
    // Load cached data first
    loadCachedUsage()

    // Skip API calls in test mode
    guard !isTestMode else { return }

    startAutoRefresh()
  }

  // Note: Singleton lives for app lifetime, no deinit needed

  var isStale: Bool {
    guard let fetched = usage?.fetchedAt else { return true }
    return Date().timeIntervalSince(fetched) > staleThreshold
  }

  func refresh() async {
    guard !isLoading else { return }
    isLoading = true
    logger.info("refresh: starting")

    let result = await Task.detached(priority: .utility) {
      Self.fetchUsageSync()
    }.value

    switch result {
      case let .success(newUsage):
        usage = newUsage
        error = nil
        saveCachedUsage()
        logger.info("refresh: success, primary=\(newUsage.primary?.usedPercent ?? -1)%")
      case let .failure(err):
        error = err
        logger.error("refresh: failed - \(err.localizedDescription)")
    }

    isLoading = false
  }

  // MARK: - Disk Cache

  private func loadCachedUsage() {
    guard let data = try? Data(contentsOf: Self.cacheURL),
          let cached = try? JSONDecoder().decode(CachedCodexUsage.self, from: data)
    else { return }

    usage = CodexUsage(
      primary: cached.primaryUsedPercent.map {
        .init(
          usedPercent: $0,
          windowDurationMins: cached.primaryWindowMins ?? 60,
          resetsAt: cached.primaryResetsAt ?? Date()
        )
      },
      secondary: cached.secondaryUsedPercent.map {
        .init(
          usedPercent: $0,
          windowDurationMins: cached.secondaryWindowMins ?? 1440,
          resetsAt: cached.secondaryResetsAt ?? Date()
        )
      },
      fetchedAt: cached.fetchedAt
    )
  }

  private func saveCachedUsage() {
    guard let usage else { return }

    let cached = CachedCodexUsage(
      primaryUsedPercent: usage.primary?.usedPercent,
      primaryWindowMins: usage.primary?.windowDurationMins,
      primaryResetsAt: usage.primary?.resetsAt,
      secondaryUsedPercent: usage.secondary?.usedPercent,
      secondaryWindowMins: usage.secondary?.windowDurationMins,
      secondaryResetsAt: usage.secondary?.resetsAt,
      fetchedAt: usage.fetchedAt
    )

    if let data = try? JSONEncoder().encode(cached) {
      try? data.write(to: Self.cacheURL)
    }
  }

  private struct CachedCodexUsage: Codable {
    let primaryUsedPercent: Double?
    let primaryWindowMins: Int?
    let primaryResetsAt: Date?
    let secondaryUsedPercent: Double?
    let secondaryWindowMins: Int?
    let secondaryResetsAt: Date?
    let fetchedAt: Date
  }

  private var isCacheValid: Bool {
    guard let fetchedAt = usage?.fetchedAt else { return false }
    return Date().timeIntervalSince(fetchedAt) < cacheValidDuration
  }

  private func startAutoRefresh() {
    refreshTask = Task { [weak self] in
      // Skip initial fetch if cache is still valid
      if self?.isCacheValid != true {
        await self?.refresh()
      }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(self?.refreshInterval ?? 300))
        await self?.refresh()
      }
    }
  }

  // MARK: - Synchronous Fetch (runs on background thread)

  private nonisolated static func fetchUsageSync() -> Result<CodexUsage, CodexUsageError> {
    guard let codexPath = findCodexBinary() else {
      return .failure(.notInstalled)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: codexPath)
    process.arguments = ["app-server"]
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

    // Set up environment
    var env = ProcessInfo.processInfo.environment
    let nodeBinDir = (codexPath as NSString).deletingLastPathComponent
    env["PATH"] = "\(nodeBinDir):\(env["PATH"] ?? "")"
    process.environment = env

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return .failure(.requestFailed("Failed to start: \(error.localizedDescription)"))
    }

    defer {
      process.terminate()
      process.waitUntilExit()
    }

    let stdin = stdinPipe.fileHandleForWriting
    let stdout = stdoutPipe.fileHandleForReading

    // Helper to send JSON-RPC
    func send(_ dict: [String: Any]) {
      guard let data = try? JSONSerialization.data(withJSONObject: dict),
            var str = String(data: data, encoding: .utf8)
      else { return }
      str += "\n"
      try? stdin.write(contentsOf: Data(str.utf8))
    }

    // Helper to read JSON-RPC response
    func readResponse() -> [String: Any]? {
      let data = stdout.availableData
      guard !data.isEmpty,
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let jsonData = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
      else { return nil }
      return json
    }

    // 1. Initialize
    send([
      "method": "initialize",
      "id": 1,
      "params": ["clientInfo": ["name": "orbitdock", "title": "OrbitDock", "version": "1.0.0"]],
    ])

    guard let initResponse = readResponse(),
          initResponse["error"] == nil
    else {
      return .failure(.requestFailed("Initialize failed"))
    }

    // 2. Send initialized notification
    send(["method": "initialized", "params": [:] as [String: Any]])

    // 3. Check auth state
    send(["method": "account/read", "id": 2, "params": ["refreshToken": false]])

    guard let authResponse = readResponse(),
          let authResult = authResponse["result"] as? [String: Any]
    else {
      return .failure(.requestFailed("Auth check failed"))
    }

    // Check auth type
    if let account = authResult["account"] as? [String: Any],
       let authType = account["type"] as? String
    {
      if authType == "apiKey" {
        return .failure(.apiKeyMode)
      }
    } else if authResult["account"] == nil || authResult["account"] is NSNull {
      return .failure(.notLoggedIn)
    }

    // 4. Fetch rate limits
    send(["method": "account/rateLimits/read", "id": 3])

    guard let limitsResponse = readResponse(),
          let limitsResult = limitsResponse["result"] as? [String: Any],
          let rateLimits = limitsResult["rateLimits"] as? [String: Any]
    else {
      return .failure(.requestFailed("Rate limits fetch failed"))
    }

    // Parse rate limits
    func parseLimit(_ dict: [String: Any]?) -> CodexUsage.RateLimit? {
      guard let dict,
            let usedPercent = dict["usedPercent"] as? Double,
            let windowMins = dict["windowDurationMins"] as? Int,
            let resetsAt = dict["resetsAt"] as? Double
      else { return nil }

      return CodexUsage.RateLimit(
        usedPercent: usedPercent,
        windowDurationMins: windowMins,
        resetsAt: Date(timeIntervalSince1970: resetsAt)
      )
    }

    let usage = CodexUsage(
      primary: parseLimit(rateLimits["primary"] as? [String: Any]),
      secondary: parseLimit(rateLimits["secondary"] as? [String: Any]),
      fetchedAt: Date()
    )

    return .success(usage)
  }

  private nonisolated static func findCodexBinary() -> String? {
    let paths = [
      "/usr/local/bin/codex",
      "/opt/homebrew/bin/codex",
      "\(FileManager.default.homeDirectoryForCurrentUser.path)/.nvm/versions/node/v24.12.0/bin/codex",
    ]

    for path in paths {
      if FileManager.default.isExecutableFile(atPath: path) {
        return path
      }
    }

    // Try which
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    proc.arguments = ["codex"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice

    do {
      try proc.run()
      proc.waitUntilExit()
      if proc.terminationStatus == 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty
        {
          return path
        }
      }
    } catch {}

    return nil
  }
}
