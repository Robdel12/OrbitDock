import Foundation

@Observable
@MainActor
final class UsageServiceRegistry {
  private let runtimeRegistry: ServerRuntimeRegistry

  private(set) var claudeWindows: [RateLimitWindow] = []
  private(set) var codexWindows: [RateLimitWindow] = []
  private(set) var claudeLoading = false
  private(set) var codexLoading = false
  private(set) var claudeError: (any LocalizedError)?
  private(set) var codexError: (any LocalizedError)?

  @ObservationIgnored private var refreshTask: Task<Void, Never>?

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

  func refreshAll() async {
    guard let clients = runtimeRegistry.runtimes.first?.clients else { return }

    // Fetch Claude usage
    claudeLoading = true
    do {
      let response = try await clients.usage.fetchClaudeUsage()
      if let usage = response.usage {
        claudeWindows = claudeUsageToWindows(usage)
      }
      claudeError = nil
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
      }
      codexError = nil
    } catch {
      codexError = UsageFetchError(message: error.localizedDescription)
    }
    codexLoading = false
  }

  func start() {
    refreshTask = Task {
      await refreshAll()
      // Refresh every 60 seconds
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled else { break }
        await refreshAll()
      }
    }
  }

  func stop() {
    refreshTask?.cancel()
    refreshTask = nil
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
  var errorDescription: String? { message }
}
