import Foundation

@Observable
@MainActor
final class UsageServiceRegistry {
  private static let warmCacheLifetime: TimeInterval = 30

  private let runtimeRegistry: ServerRuntimeRegistry

  private(set) var summary: ServerUsageSummarySnapshotPayload?
  private(set) var summaryTodayStartUnix: UInt64?
  private(set) var claudeWindows: [RateLimitWindow] = []
  private(set) var codexWindows: [RateLimitWindow] = []
  private(set) var summaryLoading = false
  private(set) var claudeLoading = false
  private(set) var codexLoading = false
  private(set) var summaryError: (any LocalizedError)?
  private(set) var claudeError: (any LocalizedError)?
  private(set) var codexError: (any LocalizedError)?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var lastRefreshCompletedAt: Date?
  @ObservationIgnored private var lastRefreshSignature: String?

  init(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  var allProviders: [Provider] {
    [.claude, .codex]
  }

  func windows(for provider: Provider) -> [RateLimitWindow] {
    switch provider {
      case .claude: claudeWindows
      case .codex: codexWindows
    }
  }

  func error(for provider: Provider) -> (any LocalizedError)? {
    switch provider {
      case .claude: claudeError
      case .codex: codexError
    }
  }

  func isLoading(for provider: Provider) -> Bool {
    switch provider {
      case .claude: claudeLoading
      case .codex: codexLoading
    }
  }

  func isStale(for provider: Provider) -> Bool {
    false
  }

  func planName(for provider: Provider) -> String? {
    nil
  }

  func refreshIfNeeded(todayStart: Date? = nil) async {
    await refresh(force: false, todayStart: todayStart)
  }

  func refreshAll(todayStart: Date? = nil) async {
    await refresh(force: true, todayStart: todayStart)
  }

  private func refresh(force: Bool, todayStart: Date?) async {
    let resolvedTodayStart = todayStart ?? Calendar.current.startOfDay(for: Date())
    let todayStartUnix = UInt64(max(resolvedTodayStart.timeIntervalSince1970, 0))
    let refreshSignature = currentRefreshSignature(todayStartUnix: todayStartUnix)

    if let refreshTask {
      await refreshTask.value
      return
    }

    guard force || shouldRefresh(signature: refreshSignature, todayStartUnix: todayStartUnix) else {
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performRefresh(
        todayStartUnix: todayStartUnix,
        signature: refreshSignature
      )
    }
    refreshTask = task
    await task.value
    if self.refreshTask != nil {
      self.refreshTask = nil
    }
  }

  private func performRefresh(
    todayStartUnix: UInt64,
    signature: String
  ) async {
    let enabledRuntimes = runtimeRegistry.runtimes.filter { $0.endpoint.isEnabled && $0.isStarted }
    let runtimes = if enabledRuntimes.isEmpty {
      [runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime]
        .compactMap { $0 }
    } else {
      enabledRuntimes
    }
    guard !runtimes.isEmpty else { return }

    summaryLoading = true
    do {
      var snapshots: [ServerUsageSummarySnapshotPayload] = []
      for runtime in runtimes {
        let snapshot = try await runtime.clients.usage.fetchUsageSummary(todayStartUnix: todayStartUnix)
        snapshots.append(snapshot)
      }
      summary = mergeUsageSummaries(snapshots)
      summaryTodayStartUnix = todayStartUnix
      summaryError = nil
    } catch {
      summaryError = UsageFetchError(message: error.localizedDescription)
    }
    summaryLoading = false

    let usageRuntime = runtimeRegistry.primaryRuntime
      ?? runtimeRegistry.activeRuntime
      ?? runtimeRegistry.runtimes.first(where: { $0.endpoint.isEnabled })
    guard let usageRuntime else { return }
    let clients = usageRuntime.clients

    // Fetch Claude usage
    claudeLoading = true
    do {
      let response = try await clients.usage.fetchClaudeUsage()
      if let usage = response.usage {
        claudeWindows = claudeUsageToWindows(usage)
        claudeError = nil
      } else if let errorInfo = response.errorInfo {
        claudeError = UsageFetchError(message: errorInfo.message)
      } else {
        claudeError = nil
      }
    } catch {
      claudeError = UsageFetchError(message: error.localizedDescription)
    }
    claudeLoading = false

    // Fetch Codex usage
    codexLoading = true
    do {
      let response = try await clients.usage.fetchCodexUsage()
      if let usage = response.usage {
        codexWindows = codexUsageToWindows(usage)
        codexError = nil
      } else if let errorInfo = response.errorInfo {
        codexError = UsageFetchError(message: errorInfo.message)
      } else {
        codexError = nil
      }
    } catch {
      codexError = UsageFetchError(message: error.localizedDescription)
    }
    codexLoading = false

    lastRefreshCompletedAt = Date()
    lastRefreshSignature = signature
  }

  private func currentRefreshSignature(todayStartUnix: UInt64) -> String {
    let enabledStartedIds = runtimeRegistry.runtimes
      .filter { $0.endpoint.isEnabled && $0.isStarted }
      .map(\.endpoint.id.uuidString)
      .sorted()

    let fallbackIds = enabledStartedIds.isEmpty
      ? [runtimeRegistry.primaryRuntime?.endpoint.id.uuidString, runtimeRegistry.activeRuntime?.endpoint.id.uuidString]
      : []

    let endpointIds = Set(enabledStartedIds + fallbackIds.compactMap { $0 }).sorted()
    return "\(todayStartUnix)|\(endpointIds.joined(separator: ","))"
  }

  private func shouldRefresh(signature: String, todayStartUnix: UInt64) -> Bool {
    guard !summaryLoading, !claudeLoading, !codexLoading else { return true }
    guard summary != nil else { return true }
    guard summaryError == nil, claudeError == nil, codexError == nil else { return true }
    guard summaryTodayStartUnix == todayStartUnix else { return true }
    guard lastRefreshSignature == signature else { return true }
    guard let lastRefreshCompletedAt else { return true }
    return Date().timeIntervalSince(lastRefreshCompletedAt) > Self.warmCacheLifetime
  }

  private func mergeUsageSummaries(_ snapshots: [ServerUsageSummarySnapshotPayload]) -> ServerUsageSummarySnapshotPayload? {
    guard !snapshots.isEmpty else { return nil }

    func mergeBuckets(_ buckets: [ServerUsageSummaryBucketPayload]) -> ServerUsageSummaryBucketPayload {
      var sessionCount: UInt64 = 0
      var totalTokens: UInt64 = 0
      var inputTokens: UInt64 = 0
      var outputTokens: UInt64 = 0
      var cachedTokens: UInt64 = 0
      var totalCostUSD = 0.0
      var modelCosts: [String: Double] = [:]

      for bucket in buckets {
        sessionCount += bucket.sessionCount
        totalTokens += bucket.totalTokens
        inputTokens += bucket.inputTokens
        outputTokens += bucket.outputTokens
        cachedTokens += bucket.cachedTokens
        totalCostUSD += bucket.totalCostUSD
        for modelCost in bucket.costByModel {
          modelCosts[modelCost.model, default: 0] += modelCost.costUSD
        }
      }

      let mergedCosts = modelCosts
        .map { ServerUsageSummaryModelCostPayload(model: $0.key, costUSD: $0.value) }
        .sorted { $0.costUSD > $1.costUSD }

      return ServerUsageSummaryBucketPayload(
        sessionCount: sessionCount,
        totalTokens: totalTokens,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedTokens: cachedTokens,
        totalCostUSD: totalCostUSD,
        costByModel: mergedCosts
      )
    }

    let today = mergeBuckets(snapshots.map(\.today))
    let allTime = mergeBuckets(snapshots.map(\.allTime))
    return ServerUsageSummarySnapshotPayload(today: today, allTime: allTime)
  }

  // MARK: - Conversion

  private func claudeUsageToWindows(_ usage: ServerClaudeUsageSnapshot) -> [RateLimitWindow] {
    var windows: [RateLimitWindow] = []

    windows.append(RateLimitWindow.fromMinutes(
      id: "claude-session",
      utilization: usage.fiveHour.utilization,
      windowMinutes: 300,
      resetsAt: parseISO8601(usage.fiveHour.resetsAt)
    ))

    if let sevenDay = usage.sevenDay {
      windows.append(RateLimitWindow.fromMinutes(
        id: "claude-all-models",
        utilization: sevenDay.utilization,
        windowMinutes: 10_080,
        resetsAt: parseISO8601(sevenDay.resetsAt)
      ))
    }

    if let sonnet = usage.sevenDaySonnet {
      windows.append(RateLimitWindow.fromMinutes(
        id: "claude-sonnet",
        utilization: sonnet.utilization,
        windowMinutes: 10_080,
        resetsAt: parseISO8601(sonnet.resetsAt)
      ))
    }

    if let opus = usage.sevenDayOpus {
      windows.append(RateLimitWindow.fromMinutes(
        id: "claude-opus",
        utilization: opus.utilization,
        windowMinutes: 10_080,
        resetsAt: parseISO8601(opus.resetsAt)
      ))
    }

    return windows
  }

  private func codexUsageToWindows(_ usage: ServerCodexUsageSnapshot) -> [RateLimitWindow] {
    var windows: [RateLimitWindow] = []

    if let primary = usage.primary {
      windows.append(RateLimitWindow.fromMinutes(
        id: "codex-primary",
        utilization: primary.usedPercent,
        windowMinutes: Int(primary.windowDurationMins),
        resetsAt: Date(timeIntervalSince1970: primary.resetsAtUnix)
      ))
    }

    if let secondary = usage.secondary {
      windows.append(RateLimitWindow.fromMinutes(
        id: "codex-secondary",
        utilization: secondary.usedPercent,
        windowMinutes: Int(secondary.windowDurationMins),
        resetsAt: Date(timeIntervalSince1970: secondary.resetsAtUnix)
      ))
    }

    return windows
  }

  private func parseISO8601(_ string: String?) -> Date? {
    guard let string else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: string)
  }
}

struct UsageFetchError: LocalizedError {
  let message: String
  var errorDescription: String? {
    message
  }
}
