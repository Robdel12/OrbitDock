//
//  ProviderMenuBarSection.swift
//  OrbitDock
//
//  Menu bar section showing usage for a single provider.
//

import SwiftUI

/// Menu bar section with provider branding and usage gauges
struct ProviderMenuBarSection: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let isLoading: Bool
  let error: (any LocalizedError)?

  /// Check if error is API key mode (for Codex)
  var isApiKeyMode: Bool {
    guard let error else { return false }
    return error.localizedDescription.contains("API key")
  }

  var body: some View {
    HStack(spacing: 0) {
      // Provider branding
      HStack(spacing: 4) {
        Image(systemName: provider.icon)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .frame(width: 60, alignment: .leading)

      if !windows.isEmpty {
        VStack(spacing: 8) {
          ForEach(windows) { window in
            GenericMenuBarGauge(window: window, provider: provider)
          }
        }
      } else if isLoading {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
      } else if let error {
        HStack(spacing: 4) {
          if isApiKeyMode {
            Image(systemName: "key.fill")
              .font(.system(size: 9))
              .foregroundStyle(provider.accentColor)
          }
          Text(error.localizedDescription)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

// MARK: - Convenience Initializers

extension ProviderMenuBarSection {
  /// Initialize from Claude subscription usage service
  init(claude service: SubscriptionUsageService) {
    self.provider = .claude
    self.isLoading = service.isLoading
    self.error = service.error

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
  VStack(spacing: 8) {
    ProviderMenuBarSection(
      provider: .claude,
      windows: [
        .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3600)),
        .sevenDay(utilization: 65, resetsAt: Date().addingTimeInterval(86400))
      ],
      isLoading: false,
      error: nil
    )

    ProviderMenuBarSection(
      provider: .codex,
      windows: [
        .fromMinutes(id: "primary", utilization: 30, windowMinutes: 15, resetsAt: Date().addingTimeInterval(600))
      ],
      isLoading: false,
      error: nil
    )
  }
  .padding()
  .frame(width: 280)
  .background(Color.backgroundPrimary)
}
