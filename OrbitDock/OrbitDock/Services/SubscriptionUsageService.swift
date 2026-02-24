//
//  SubscriptionUsageService.swift
//  OrbitDock
//
//  Fetches Claude subscription usage from the selected control-plane server endpoint.
//

import Foundation

// MARK: - Models

struct SubscriptionUsage: Sendable {
  struct Window: Sendable {
    let utilization: Double // 0-100
    let resetsAt: Date?
    let windowDuration: TimeInterval // 5 hours or 7 days in seconds

    var remaining: Double {
      max(0, 100 - utilization)
    }

    var resetsInDescription: String? {
      guard let resetsAt else { return nil }
      let interval = resetsAt.timeIntervalSinceNow
      if interval <= 0 { return "now" }

      let hours = Int(interval / 3_600)
      let minutes = Int((interval.truncatingRemainder(dividingBy: 3_600)) / 60)

      if hours > 0 {
        return "\(hours)h \(minutes)m"
      }
      return "\(minutes)m"
    }

    /// Time remaining until reset
    var timeRemaining: TimeInterval {
      guard let resetsAt else { return 0 }
      return max(0, resetsAt.timeIntervalSinceNow)
    }

    /// Time elapsed since window started
    var timeElapsed: TimeInterval {
      windowDuration - timeRemaining
    }

    /// Current burn rate (% per hour)
    var burnRatePerHour: Double {
      guard timeElapsed > 0 else { return 0 }
      return utilization / (timeElapsed / 3_600)
    }

    /// Projected usage at reset if current pace continues
    var projectedAtReset: Double {
      guard timeElapsed > 60 else { return utilization } // Need at least 1 min of data
      let rate = utilization / timeElapsed
      return max(0, rate * windowDuration)
    }

    /// Whether on track to exceed the limit
    var willExceed: Bool {
      projectedAtReset > 95 // Give 5% buffer
    }

    /// Pace status
    var paceStatus: PaceStatus {
      // If very early in window, not enough data
      if timeElapsed < 300 { return .unknown } // 5 min minimum

      let sustainableRate = 100.0 / (windowDuration / 3_600) // % per hour to use exactly 100%
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

  let fiveHour: Window
  let sevenDay: Window?
  let sevenDaySonnet: Window?
  let sevenDayOpus: Window?
  let fetchedAt: Date
  let rateLimitTier: String?

  var planName: String? {
    guard let tier = rateLimitTier?.lowercased() else { return nil }
    if tier.contains("max_20x") { return "Max 20x" }
    if tier.contains("max_5x") { return "Max 5x" }
    if tier.contains("max") { return "Max" }
    if tier.contains("pro") { return "Pro" }
    if tier.contains("team") { return "Team" }
    if tier.contains("enterprise") { return "Enterprise" }
    return nil
  }

  /// Convert to unified RateLimitWindow array for generic UI components
  var windows: [RateLimitWindow] {
    var result: [RateLimitWindow] = [
      .fiveHour(utilization: fiveHour.utilization, resetsAt: fiveHour.resetsAt),
    ]
    if let sevenDay {
      result.append(.sevenDay(utilization: sevenDay.utilization, resetsAt: sevenDay.resetsAt))
    }
    return result
  }
}

enum SubscriptionUsageError: LocalizedError {
  case noCredentials
  case tokenExpired
  case unauthorized
  case networkError(Error)
  case invalidResponse
  case missingScope
  case requestFailed(String)

  var errorDescription: String? {
    switch self {
      case .noCredentials: "No Claude credentials found"
      case .tokenExpired: "Claude token expired - restart Claude CLI to refresh"
      case .unauthorized: "Unauthorized - check Claude CLI login"
      case let .networkError(e): "Network error: \(e.localizedDescription)"
      case .invalidResponse: "Invalid API response"
      case .missingScope: "Token missing user:profile scope"
      case let .requestFailed(message): message
    }
  }
}

// MARK: - Service

@Observable
@MainActor
final class SubscriptionUsageService {
  static let shared = SubscriptionUsageService()

  private(set) var usage: SubscriptionUsage?
  private(set) var error: SubscriptionUsageError?
  private(set) var isLoading = false
  private(set) var lastFetchAttempt: Date?

  // Refresh interval
  private let refreshInterval: TimeInterval = 60 // 1 minute
  private let staleThreshold: TimeInterval = 300 // 5 minutes before showing stale
  private let cacheValidDuration: TimeInterval = 120 // 2 minutes

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

  // MARK: - Public API

  func refresh() async {
    guard !isLoading else { return }
    guard let context = controlPlaneContext() else {
      error = .requestFailed("No control-plane server configured")
      return
    }

    switchActiveEndpointIfNeeded(context.endpointId)

    isLoading = true
    lastFetchAttempt = Date()

    do {
      let response = try await context.connection.fetchClaudeUsage()
      if let errorInfo = response.errorInfo {
        error = mapServerError(errorInfo)
      } else if let snapshot = response.usage {
        usage = Self.mapSnapshot(snapshot)
        error = nil
        saveCachedUsage(for: context.endpointId)
      } else {
        error = .requestFailed("No Claude usage data returned")
      }
    } catch {
      self.error = .requestFailed(error.localizedDescription)
    }

    isLoading = false
  }

  var isStale: Bool {
    guard let fetched = usage?.fetchedAt else { return true }
    return Date().timeIntervalSince(fetched) > staleThreshold
  }

  // MARK: - Control Plane Endpoint

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

  // MARK: - Disk Cache

  private func cacheURL(for endpointId: UUID) -> URL {
    let cacheDir = PlatformPaths.orbitDockCacheDirectory
    try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    return cacheDir.appendingPathComponent("claude-usage-\(endpointId.uuidString).json")
  }

  private func loadCachedUsage(for endpointId: UUID) -> SubscriptionUsage? {
    let url = cacheURL(for: endpointId)
    guard let data = try? Data(contentsOf: url),
          let cached = try? JSONDecoder().decode(CachedUsage.self, from: data)
    else { return nil }

    return SubscriptionUsage(
      fiveHour: .init(
        utilization: cached.fiveHourUtilization,
        resetsAt: cached.fiveHourResetsAt,
        windowDuration: 5 * 3_600
      ),
      sevenDay: cached.sevenDayUtilization.map {
        .init(utilization: $0, resetsAt: cached.sevenDayResetsAt, windowDuration: 7 * 24 * 3_600)
      },
      sevenDaySonnet: nil,
      sevenDayOpus: nil,
      fetchedAt: cached.fetchedAt,
      rateLimitTier: cached.rateLimitTier
    )
  }

  private func saveCachedUsage(for endpointId: UUID) {
    guard let usage else { return }

    let cached = CachedUsage(
      fiveHourUtilization: usage.fiveHour.utilization,
      fiveHourResetsAt: usage.fiveHour.resetsAt,
      sevenDayUtilization: usage.sevenDay?.utilization,
      sevenDayResetsAt: usage.sevenDay?.resetsAt,
      fetchedAt: usage.fetchedAt,
      rateLimitTier: usage.rateLimitTier
    )

    if let data = try? JSONEncoder().encode(cached) {
      try? data.write(to: cacheURL(for: endpointId))
    }
  }

  private struct CachedUsage: Codable {
    let fiveHourUtilization: Double
    let fiveHourResetsAt: Date?
    let sevenDayUtilization: Double?
    let sevenDayResetsAt: Date?
    let fetchedAt: Date
    let rateLimitTier: String?
  }

  private var isCacheValid: Bool {
    guard let fetchedAt = usage?.fetchedAt else { return false }
    return Date().timeIntervalSince(fetchedAt) < cacheValidDuration
  }

  // MARK: - Auto Refresh

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

  // MARK: - Mapping

  private func mapServerError(_ errorInfo: ServerUsageErrorInfo) -> SubscriptionUsageError {
    switch errorInfo.code {
      case "no_credentials":
        .noCredentials
      case "token_expired":
        .tokenExpired
      case "unauthorized":
        .unauthorized
      case "missing_scope":
        .missingScope
      case "network_error":
        .requestFailed(errorInfo.message)
      case "invalid_response":
        .invalidResponse
      default:
        .requestFailed(errorInfo.message)
    }
  }

  private nonisolated static func mapSnapshot(_ snapshot: ServerClaudeUsageSnapshot) -> SubscriptionUsage {
    let fiveHourDuration: TimeInterval = 5 * 3_600
    let sevenDayDuration: TimeInterval = 7 * 24 * 3_600

    func parseWindow(_ window: ServerClaudeUsageWindow?, duration: TimeInterval) -> SubscriptionUsage.Window? {
      guard let window else { return nil }
      return SubscriptionUsage.Window(
        utilization: window.utilization,
        resetsAt: parseISODate(window.resetsAt),
        windowDuration: duration
      )
    }

    let fiveHour = parseWindow(snapshot.fiveHour, duration: fiveHourDuration)
      ?? SubscriptionUsage.Window(utilization: 0, resetsAt: nil, windowDuration: fiveHourDuration)

    return SubscriptionUsage(
      fiveHour: fiveHour,
      sevenDay: parseWindow(snapshot.sevenDay, duration: sevenDayDuration),
      sevenDaySonnet: parseWindow(snapshot.sevenDaySonnet, duration: sevenDayDuration),
      sevenDayOpus: parseWindow(snapshot.sevenDayOpus, duration: sevenDayDuration),
      fetchedAt: Date(timeIntervalSince1970: normalizedUnixTime(snapshot.fetchedAtUnix)),
      rateLimitTier: snapshot.rateLimitTier
    )
  }

  private nonisolated static func parseISODate(_ value: String?) -> Date? {
    guard let value else { return nil }

    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: value) {
      return date
    }

    let basic = ISO8601DateFormatter()
    basic.formatOptions = [.withInternetDateTime]
    return basic.date(from: value)
  }

  private nonisolated static func normalizedUnixTime(_ value: Double) -> TimeInterval {
    value > 4_102_444_800 ? value / 1_000 : value
  }
}
