import Foundation

struct UsageEndpointSnapshot: Identifiable {
  let endpointId: UUID
  let endpointName: String
  let overview: ServerUsageOverviewSnapshotPayload
  let usageSessions: ServerUsageSessionsSnapshotPayload
  let claudeWindows: [RateLimitWindow]
  let codexWindows: [RateLimitWindow]
  let claudeErrorMessage: String?
  let codexErrorMessage: String?
  let codexRateLimitReachedType: ServerCodexRateLimitReachedType?

  var id: UUID { endpointId }
}

@Observable
@MainActor
final class UsageServiceRegistry {
  private static let warmCacheLifetime: TimeInterval = 30

  private let runtimeRegistry: ServerRuntimeRegistry
  private static let recentDayWindow: UInt64 = 6 * 86_400

  private(set) var summary: ServerUsageSummarySnapshotPayload?
  private(set) var endpointSnapshots: [UsageEndpointSnapshot] = []
  private(set) var providerBreakdown: ServerUsageBreakdownSnapshotPayload?
  private(set) var modelBreakdown: ServerUsageBreakdownSnapshotPayload?
  private(set) var topSessions: ServerUsageSessionsSnapshotPayload?
  private(set) var recentDayBreakdown: ServerUsageBreakdownSnapshotPayload?
  private(set) var summaryTodayStartUnix: UInt64?
  private(set) var claudeWindows: [RateLimitWindow] = []
  private(set) var codexWindows: [RateLimitWindow] = []
  private(set) var codexRateLimitReachedType: ServerCodexRateLimitReachedType?
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
    let recentDayStartUnix = todayStartUnix >= Self.recentDayWindow
      ? todayStartUnix - Self.recentDayWindow
      : 0
    let enabledRuntimes = runtimeRegistry.runtimes.filter { $0.endpoint.isEnabled && $0.isStarted }
    let runtimes = if enabledRuntimes.isEmpty {
      [runtimeRegistry.primaryRuntime ?? runtimeRegistry.activeRuntime]
        .compactMap { $0 }
    } else {
      enabledRuntimes
    }
    guard !runtimes.isEmpty else { return }

    summaryLoading = true
    claudeLoading = true
    codexLoading = true
    var endpointSnapshots: [UsageEndpointSnapshot] = []
    var errors: [String] = []
    for runtime in runtimes {
      do {
        let snapshot = try await fetchEndpointSnapshot(runtime: runtime, todayStartUnix: todayStartUnix)
        endpointSnapshots.append(snapshot)
      } catch {
        errors.append("\(runtime.endpoint.name): \(error.localizedDescription)")
      }
    }

    if !endpointSnapshots.isEmpty {
      self.endpointSnapshots = endpointSnapshots
      summary = mergeUsageSummaries(endpointSnapshots.map(\.overview.summary))
      providerBreakdown = mergeUsageBreakdowns(
        endpointSnapshots.map(\.overview.todayProviderBreakdown),
        groupBy: .provider,
        startUnix: todayStartUnix
      )
      modelBreakdown = mergeUsageBreakdowns(
        endpointSnapshots.map(\.overview.todayModelBreakdown),
        groupBy: .model,
        startUnix: todayStartUnix
      )
      topSessions = mergeUsageSessions(endpointSnapshots.map(\.usageSessions))
      recentDayBreakdown = mergeUsageBreakdowns(
        endpointSnapshots.map(\.overview.dayBreakdown),
        groupBy: .day,
        startUnix: recentDayStartUnix
      )
      summaryTodayStartUnix = todayStartUnix
      summaryError = errors.isEmpty
        ? nil
        : UsageFetchError(message: "Some usage endpoints failed:\n\(errors.joined(separator: "\n"))")
    } else {
      self.endpointSnapshots = []
      providerBreakdown = nil
      modelBreakdown = nil
      topSessions = nil
      recentDayBreakdown = nil
      let message = errors.isEmpty ? "No usage endpoints are available." : errors.joined(separator: "\n")
      summaryError = UsageFetchError(message: message)
    }

    let selectedEndpointId = (
      runtimeRegistry.primaryRuntime
        ?? runtimeRegistry.activeRuntime
        ?? runtimeRegistry.runtimes.first(where: { $0.endpoint.isEnabled })
    )?.endpoint.id
    let selectedSnapshot = endpointSnapshots.first(where: { $0.endpointId == selectedEndpointId }) ?? endpointSnapshots.first

    claudeWindows = selectedSnapshot?.claudeWindows ?? []
    codexWindows = selectedSnapshot?.codexWindows ?? []
    claudeError = selectedSnapshot?.claudeErrorMessage.map(UsageFetchError.init(message:))
    codexError = selectedSnapshot?.codexErrorMessage.map(UsageFetchError.init(message:))
    codexRateLimitReachedType = selectedSnapshot?.codexRateLimitReachedType
    summaryLoading = false
    claudeLoading = false
    codexLoading = false

    lastRefreshCompletedAt = Date()
    lastRefreshSignature = signature
  }

  private func fetchEndpointSnapshot(
    runtime: ServerRuntime,
    todayStartUnix: UInt64
  ) async throws -> UsageEndpointSnapshot {
    let clients = runtime.clients.usage
    let recentDayStartUnix = todayStartUnix >= Self.recentDayWindow
      ? todayStartUnix - Self.recentDayWindow
      : 0
    let overview = try await clients.fetchUsageOverview(
      todayStartUnix: todayStartUnix,
      rangeStartUnix: recentDayStartUnix
    )
    let usageSessions = try await clients.fetchUsageSessions(
      startUnix: todayStartUnix,
      limit: 12
    )
    let claudeState = await fetchClaudeState(clients: clients)
    let codexState = await fetchCodexState(clients: clients)
    return UsageEndpointSnapshot(
      endpointId: runtime.endpoint.id,
      endpointName: runtime.endpoint.name,
      overview: overview,
      usageSessions: usageSessions,
      claudeWindows: claudeState.windows,
      codexWindows: codexState.windows,
      claudeErrorMessage: claudeState.errorMessage,
      codexErrorMessage: codexState.errorMessage,
      codexRateLimitReachedType: codexState.rateLimitReachedType
    )
  }

  private func fetchClaudeState(
    clients: UsageClient
  ) async -> (windows: [RateLimitWindow], errorMessage: String?) {
    do {
      let response = try await clients.fetchClaudeUsage()
      if let usage = response.usage {
        return (claudeUsageToWindows(usage), nil)
      }
      return ([], response.errorInfo?.message)
    } catch {
      return ([], error.localizedDescription)
    }
  }

  private func fetchCodexState(
    clients: UsageClient
  ) async -> (
    windows: [RateLimitWindow],
    errorMessage: String?,
    rateLimitReachedType: ServerCodexRateLimitReachedType?
  ) {
    do {
      let response = try await clients.fetchCodexUsage()
      if let usage = response.usage {
        return (codexUsageToWindows(usage), nil, usage.rateLimitReachedType)
      }
      return ([], response.errorInfo?.message, nil)
    } catch {
      return ([], error.localizedDescription, nil)
    }
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

    let today = mergeBuckets(snapshots.map(\.today))
    let allTime = mergeBuckets(snapshots.map(\.allTime))
    return ServerUsageSummarySnapshotPayload(today: today, allTime: allTime)
  }

  private func mergeUsageBreakdowns(
    _ snapshots: [ServerUsageBreakdownSnapshotPayload],
    groupBy: ServerUsageBreakdownGroupBy,
    startUnix: UInt64?
  ) -> ServerUsageBreakdownSnapshotPayload? {
    guard !snapshots.isEmpty else { return nil }

    var grouped: [String: ServerUsageBreakdownEntryPayload] = [:]
    for entry in snapshots.flatMap(\.groups) {
      let existing = grouped[entry.groupKey]
      grouped[entry.groupKey] = ServerUsageBreakdownEntryPayload(
        groupKey: entry.groupKey,
        provider: entry.provider ?? existing?.provider,
        model: entry.model ?? existing?.model,
        sessionId: entry.sessionId ?? existing?.sessionId,
        dayStartUnix: entry.dayStartUnix ?? existing?.dayStartUnix,
        turnCount: (existing?.turnCount ?? 0) + entry.turnCount,
        sessionCount: (existing?.sessionCount ?? 0) + entry.sessionCount,
        distinctSessionCount: (existing?.distinctSessionCount ?? 0) + entry.distinctSessionCount,
        inputTokens: (existing?.inputTokens ?? 0) + entry.inputTokens,
        outputTokens: (existing?.outputTokens ?? 0) + entry.outputTokens,
        cachedTokens: (existing?.cachedTokens ?? 0) + entry.cachedTokens,
        totalTokens: (existing?.totalTokens ?? 0) + entry.totalTokens,
        totalCostUSD: (existing?.totalCostUSD ?? 0) + entry.totalCostUSD
      )
    }

    let totals = mergeBuckets(snapshots.map(\.totals))
    let groups = grouped.values.sorted { lhs, rhs in
      if lhs.totalCostUSD == rhs.totalCostUSD {
        return lhs.totalTokens > rhs.totalTokens
      }
      return lhs.totalCostUSD > rhs.totalCostUSD
    }

    return ServerUsageBreakdownSnapshotPayload(
      groupBy: groupBy,
      startUnix: startUnix,
      endUnix: nil,
      totals: totals,
      groups: groups
    )
  }

  private func mergeBuckets(_ buckets: [ServerUsageSummaryBucketPayload]) -> ServerUsageSummaryBucketPayload {
    var sessionCount: UInt64 = 0
    var distinctSessionCount: UInt64 = 0
    var totalTokens: UInt64 = 0
    var inputTokens: UInt64 = 0
    var outputTokens: UInt64 = 0
    var cachedTokens: UInt64 = 0
    var totalCostUSD = 0.0
    var modelCosts: [String: Double] = [:]

    for bucket in buckets {
      sessionCount += bucket.sessionCount
      distinctSessionCount += bucket.distinctSessionCount
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
      distinctSessionCount: distinctSessionCount,
      totalTokens: totalTokens,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedTokens: cachedTokens,
      totalCostUSD: totalCostUSD,
      costByModel: mergedCosts
    )
  }

  private func mergeUsageSessions(
    _ snapshots: [ServerUsageSessionsSnapshotPayload]
  ) -> ServerUsageSessionsSnapshotPayload? {
    guard !snapshots.isEmpty else { return nil }

    var merged: [String: ServerUsageSessionSummaryPayload] = [:]
    for session in snapshots.flatMap(\.sessions) {
      if let existing = merged[session.sessionId] {
        merged[session.sessionId] = ServerUsageSessionSummaryPayload(
          sessionId: session.sessionId,
          provider: session.provider,
          displayName: existing.displayName,
          projectName: existing.projectName ?? session.projectName,
          projectPath: existing.projectPath,
          model: existing.model ?? session.model,
          startedAt: existing.startedAt ?? session.startedAt,
          lastActivityAt: max(existing.lastActivityAt ?? "", session.lastActivityAt ?? "").nilIfEmpty,
          contextLine: existing.contextLine ?? session.contextLine,
          turnCount: existing.turnCount + session.turnCount,
          inputTokens: existing.inputTokens + session.inputTokens,
          outputTokens: existing.outputTokens + session.outputTokens,
          cachedTokens: existing.cachedTokens + session.cachedTokens,
          totalTokens: existing.totalTokens + session.totalTokens,
          totalCostUSD: existing.totalCostUSD + session.totalCostUSD
        )
      } else {
        merged[session.sessionId] = session
      }
    }

    let orderedSessions = merged.values.sorted { lhs, rhs in
      if lhs.totalCostUSD == rhs.totalCostUSD {
        if lhs.totalTokens == rhs.totalTokens {
          return lhs.displayName < rhs.displayName
        }
        return lhs.totalTokens > rhs.totalTokens
      }
      return lhs.totalCostUSD > rhs.totalCostUSD
    }

    return ServerUsageSessionsSnapshotPayload(
      startUnix: snapshots.compactMap(\.startUnix).min(),
      endUnix: snapshots.compactMap(\.endUnix).max(),
      nextOffset: nil,
      totalCount: UInt64(orderedSessions.count),
      sessions: Array(orderedSessions.prefix(12))
    )
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
