//
//  UsageServiceRegistry.swift
//  OrbitDock
//
//  Coordinates all usage services and provides unified access.
//

import Foundation

/// Registry for all provider usage services
@Observable
@MainActor
final class UsageServiceRegistry {
  static let shared = UsageServiceRegistry()

  let claude = SubscriptionUsageService.shared
  let codex = CodexUsageService.shared

  private init() {}

  /// Returns providers that have valid data (not errored or loading)
  var activeProviders: [Provider] {
    var providers: [Provider] = []

    // Claude is always available if logged in
    if claude.usage != nil || claude.isLoading {
      providers.append(.claude)
    }

    // Codex is available if installed (even API key mode shows as available)
    if codex.usage != nil || codex.isLoading || isCodexApiKeyMode {
      providers.append(.codex)
    }

    return providers
  }

  /// All supported providers (for showing placeholders/errors)
  var allProviders: [Provider] {
    [.claude, .codex]
  }

  /// Check if Codex is in API key mode
  private var isCodexApiKeyMode: Bool {
    guard let error = codex.error else { return false }
    return error.localizedDescription.contains("API key")
  }

  /// Refresh all services
  func refreshAll() async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.claude.refresh() }
      group.addTask { await self.codex.refresh() }
    }
  }

  /// Get windows for a specific provider
  func windows(for provider: Provider) -> [RateLimitWindow] {
    switch provider {
      case .claude:
        claudeWindows
      case .codex:
        codexWindows
    }
  }

  /// Get error for a specific provider
  func error(for provider: Provider) -> (any LocalizedError)? {
    switch provider {
      case .claude:
        claude.error
      case .codex:
        codex.error
    }
  }

  /// Check if provider is loading
  func isLoading(for provider: Provider) -> Bool {
    switch provider {
      case .claude:
        claude.isLoading
      case .codex:
        codex.isLoading
    }
  }

  /// Check if provider data is stale
  func isStale(for provider: Provider) -> Bool {
    switch provider {
      case .claude:
        claude.isStale
      case .codex:
        codex.isStale
    }
  }

  /// Get plan name for a provider (if available)
  func planName(for provider: Provider) -> String? {
    switch provider {
      case .claude:
        claude.usage?.planName
      case .codex:
        nil
    }
  }

  // MARK: - Private Helpers

  private var claudeWindows: [RateLimitWindow] {
    guard let usage = claude.usage else { return [] }

    var windows: [RateLimitWindow] = [
      .fiveHour(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt),
    ]

    if let sevenDay = usage.sevenDay {
      windows.append(.sevenDay(utilization: sevenDay.utilization, resetsAt: sevenDay.resetsAt))
    }

    return windows
  }

  private var codexWindows: [RateLimitWindow] {
    guard let usage = codex.usage, let primary = usage.primary else { return [] }

    var windows: [RateLimitWindow] = [
      .fromMinutes(
        id: "primary",
        utilization: primary.usedPercent,
        windowMinutes: primary.windowDurationMins,
        resetsAt: primary.resetsAt
      ),
    ]

    if let secondary = usage.secondary {
      windows.append(.fromMinutes(
        id: "secondary",
        utilization: secondary.usedPercent,
        windowMinutes: secondary.windowDurationMins,
        resetsAt: secondary.resetsAt
      ))
    }

    return windows
  }
}
