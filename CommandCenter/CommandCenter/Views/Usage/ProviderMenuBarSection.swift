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
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 6) {
        Image(systemName: provider.icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.primary)
      }

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
        .padding(.vertical, 6)
      } else if let error {
        HStack(spacing: 6) {
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
    .padding(.horizontal, 9)
    .padding(.vertical, 8)
    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .fiveHour(utilization: usage.fiveHour.utilization, resetsAt: usage.fiveHour.resetsAt),
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
        .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3_600)),
        .sevenDay(utilization: 65, resetsAt: Date().addingTimeInterval(86_400)),
      ],
      isLoading: false,
      error: nil
    )

    ProviderMenuBarSection(
      provider: .codex,
      windows: [
        .fromMinutes(id: "primary", utilization: 30, windowMinutes: 15, resetsAt: Date().addingTimeInterval(600)),
      ],
      isLoading: false,
      error: nil
    )
  }
  .padding()
  .frame(width: 280)
  .background(Color.backgroundPrimary)
}
