import Foundation

@Observable
@MainActor
final class UsageServiceRegistry {
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

  func refreshAll(todayStart: Date? = nil) async {
    guard let runtime = runtimeRegistry.primaryRuntime
      ?? runtimeRegistry.activeRuntime
      ?? runtimeRegistry.runtimes.first(where: { $0.endpoint.isEnabled })
    else { return }
    let clients = runtime.clients

    let todayStartUnix = todayStart.map { UInt64(max($0.timeIntervalSince1970, 0)) }

    summaryLoading = true
    do {
      summary = try await clients.usage.fetchUsageSummary(todayStartUnix: todayStartUnix)
      summaryTodayStartUnix = todayStartUnix
      summaryError = nil
    } catch {
      summaryError = UsageFetchError(message: error.localizedDescription)
    }
    summaryLoading = false

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
