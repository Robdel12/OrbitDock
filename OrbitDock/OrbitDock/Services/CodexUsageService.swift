//
//  CodexUsageService.swift
//  OrbitDock
//
//  Fetches Codex/ChatGPT usage from the selected control-plane server endpoint.
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

    var remaining: Double {
      max(0, 100 - usedPercent)
    }

    var resetsInDescription: String {
      let interval = resetsAt.timeIntervalSinceNow
      if interval <= 0 { return "now" }
      let hours = Int(interval / 3_600)
      let minutes = Int((interval.truncatingRemainder(dividingBy: 3_600)) / 60)
      return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var timeRemaining: TimeInterval {
      max(0, resetsAt.timeIntervalSinceNow)
    }

    var windowDuration: TimeInterval {
      TimeInterval(windowDurationMins * 60)
    }

    var timeElapsed: TimeInterval {
      windowDuration - timeRemaining
    }

    var burnRatePerHour: Double {
      guard timeElapsed > 0 else { return 0 }
      return usedPercent / (timeElapsed / 3_600)
    }

    var projectedAtReset: Double {
      guard timeElapsed > 60 else { return usedPercent }
      let rate = usedPercent / timeElapsed
      return max(0, rate * windowDuration)
    }

    var willExceed: Bool {
      projectedAtReset > 95
    }

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
  private let cacheValidDuration: TimeInterval = 180 // 3 minutes
  private var refreshTask: Task<Void, Never>?
  private var endpointObserver: NSObjectProtocol?
  private var activeEndpointId: UUID?

  private var isTestMode: Bool {
    ProcessInfo.processInfo.environment["ORBITDOCK_TEST_DB"] != nil
  }

  private init() {
    observeControlPlaneEndpointChanges()

    if let context = controlPlaneContext() {
      switchActiveEndpointIfNeeded(context.endpointId)
    }

    guard !isTestMode else { return }
    startAutoRefresh()
  }

  var isStale: Bool {
    guard let fetched = usage?.fetchedAt else { return true }
    return Date().timeIntervalSince(fetched) > staleThreshold
  }

  func refresh() async {
    guard !isLoading else { return }

    guard let context = controlPlaneContext() else {
      error = .requestFailed("No control-plane server configured")
      return
    }

    switchActiveEndpointIfNeeded(context.endpointId)

    isLoading = true
    logger.info("refresh: starting endpoint=\(context.endpointId.uuidString, privacy: .public)")

    do {
      let response = try await context.connection.fetchCodexUsage()
      if let errorInfo = response.errorInfo {
        error = mapServerError(errorInfo)
        logger.error("refresh: failed - \(errorInfo.message, privacy: .public)")
      } else if let snapshot = response.usage {
        let newUsage = Self.mapSnapshot(snapshot)
        usage = newUsage
        error = nil
        saveCachedUsage(for: context.endpointId)
        logger.info("refresh: success, primary=\(newUsage.primary?.usedPercent ?? -1)%")
      } else {
        error = .requestFailed("No Codex usage data returned")
      }
    } catch {
      self.error = .requestFailed(error.localizedDescription)
      logger.error("refresh: transport failed - \(error.localizedDescription, privacy: .public)")
    }

    isLoading = false
  }

  private func observeControlPlaneEndpointChanges() {
    endpointObserver = NotificationCenter.default.addObserver(
      forName: .serverPrimaryEndpointDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      Task { @MainActor in
        await self?.refresh()
      }
    }
  }

  private func startAutoRefresh() {
    refreshTask = Task { [weak self] in
      guard let self else { return }
      if self.isCacheValid != true {
        await self.refresh()
      }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(self.refreshInterval))
        await self.refresh()
      }
    }
  }

  private var isCacheValid: Bool {
    guard let fetchedAt = usage?.fetchedAt else { return false }
    return Date().timeIntervalSince(fetchedAt) < cacheValidDuration
  }

  private func controlPlaneContext() -> (endpointId: UUID, connection: ServerConnection)? {
    let runtimeRegistry = ServerRuntimeRegistry.shared
    guard let connection = runtimeRegistry.controlPlaneConnection else {
      return nil
    }
    return (connection.endpointId, connection)
  }

  private func switchActiveEndpointIfNeeded(_ endpointId: UUID) {
    guard activeEndpointId != endpointId else { return }
    activeEndpointId = endpointId
    usage = loadCachedUsage(for: endpointId)
    error = nil
  }

  private func cacheURL(for endpointId: UUID) -> URL {
    let cacheDir = PlatformPaths.orbitDockCacheDirectory
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    return cacheDir.appendingPathComponent("codex-usage-\(endpointId.uuidString).json")
  }

  private func loadCachedUsage(for endpointId: UUID) -> CodexUsage? {
    let url = cacheURL(for: endpointId)
    guard let data = try? Data(contentsOf: url),
          let cached = try? JSONDecoder().decode(CachedCodexUsage.self, from: data)
    else { return nil }

    return CodexUsage(
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
          windowDurationMins: cached.secondaryWindowMins ?? 1_440,
          resetsAt: cached.secondaryResetsAt ?? Date()
        )
      },
      fetchedAt: cached.fetchedAt
    )
  }

  private func saveCachedUsage(for endpointId: UUID) {
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
      try? data.write(to: cacheURL(for: endpointId))
    }
  }

  private func mapServerError(_ errorInfo: ServerUsageErrorInfo) -> CodexUsageError {
    switch errorInfo.code {
      case "not_installed":
        .notInstalled
      case "not_logged_in":
        .notLoggedIn
      case "api_key_mode":
        .apiKeyMode
      default:
        .requestFailed(errorInfo.message)
    }
  }

  private nonisolated static func mapSnapshot(_ snapshot: ServerCodexUsageSnapshot) -> CodexUsage {
    func toRateLimit(_ limit: ServerCodexRateLimitWindow?) -> CodexUsage.RateLimit? {
      guard let limit else { return nil }
      let unix = normalizedUnixTime(limit.resetsAtUnix)
      return CodexUsage.RateLimit(
        usedPercent: limit.usedPercent,
        windowDurationMins: Int(limit.windowDurationMins),
        resetsAt: Date(timeIntervalSince1970: unix)
      )
    }

    return CodexUsage(
      primary: toRateLimit(snapshot.primary),
      secondary: toRateLimit(snapshot.secondary),
      fetchedAt: Date(timeIntervalSince1970: normalizedUnixTime(snapshot.fetchedAtUnix))
    )
  }

  private nonisolated static func normalizedUnixTime(_ value: Double) -> TimeInterval {
    value > 4_102_444_800 ? value / 1_000 : value
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
}
