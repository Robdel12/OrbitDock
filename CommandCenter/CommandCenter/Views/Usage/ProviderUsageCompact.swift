//
//  ProviderUsageCompact.swift
//  OrbitDock
//
//  Compact usage display for headers - shows provider icon + usage bars.
//

import SwiftUI

/// Compact inline usage display with provider icon and progress bars
struct ProviderUsageCompact: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let isLoading: Bool
  let error: (any LocalizedError)?
  let isStale: Bool

  /// Check if error is API key mode (for Codex)
  var isApiKeyMode: Bool {
    guard let error else { return false }
    return error.localizedDescription.contains("API key")
  }

  var body: some View {
    HStack(spacing: 8) {
      // Provider icon
      Image(systemName: provider.icon)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(provider.accentColor)

      if !windows.isEmpty {
        HStack(spacing: 12) {
          ForEach(windows) { window in
            GenericUsageBar(window: window, provider: provider)
          }
        }
      } else if isLoading {
        ProgressView()
          .controlSize(.mini)
      } else if let error {
        HStack(spacing: 3) {
          Image(systemName: isApiKeyMode ? "key.fill" : "exclamationmark.triangle")
            .font(.system(size: 9))
            .foregroundStyle(isApiKeyMode ? provider.accentColor : Color.statusError)
          if isApiKeyMode {
            Text("API")
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(.tertiary)
          }
        }
        .help(error.localizedDescription)
      }
    }
    .opacity(isStale ? 0.6 : 1.0)
  }
}

// MARK: - Convenience Initializers

extension ProviderUsageCompact {
  /// Initialize from Claude subscription usage service
  init(claude service: SubscriptionUsageService) {
    self.provider = .claude
    self.isLoading = service.isLoading
    self.error = service.error
    self.isStale = service.isStale

    if let usage = service.usage {
      var windows: [RateLimitWindow] = [
        .fiveHour(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt)
      ]
      if let sevenDay = usage.sevenDay {
        windows.append(.sevenDay(utilization: sevenDay.utilization, resetsAt: sevenDay.resetsAt))
      }
      self.windows = windows
    } else {
      self.windows = []
    }
  }

  /// Initialize from Codex usage service
  @MainActor
  init(codex service: CodexUsageService) {
    self.provider = .codex
    self.isLoading = service.isLoading
    self.error = service.error
    self.isStale = service.isStale

    if let usage = service.usage, let primary = usage.primary {
      var windows: [RateLimitWindow] = [
        .fromMinutes(id: "primary", utilization: primary.usedPercent, windowMinutes: primary.windowDurationMins, resetsAt: primary.resetsAt)
      ]
      if let secondary = usage.secondary {
        windows.append(.fromMinutes(id: "secondary", utilization: secondary.usedPercent, windowMinutes: secondary.windowDurationMins, resetsAt: secondary.resetsAt))
      }
      self.windows = windows
    } else {
      self.windows = []
    }
  }
}

#Preview {
  VStack(spacing: 16) {
    ProviderUsageCompact(
      provider: .claude,
      windows: [
        .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3600)),
        .sevenDay(utilization: 65, resetsAt: Date().addingTimeInterval(86400))
      ],
      isLoading: false,
      error: nil,
      isStale: false
    )

    ProviderUsageCompact(
      provider: .codex,
      windows: [
        .fromMinutes(id: "primary", utilization: 30, windowMinutes: 15, resetsAt: Date().addingTimeInterval(600))
      ],
      isLoading: false,
      error: nil,
      isStale: false
    )

    ProviderUsageCompact(
      provider: .codex,
      windows: [],
      isLoading: true,
      error: nil,
      isStale: false
    )
  }
  .padding()
  .background(Color.backgroundSecondary)
}
