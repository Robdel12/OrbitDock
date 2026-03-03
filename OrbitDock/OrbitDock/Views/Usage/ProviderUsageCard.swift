//
//  ProviderUsageCard.swift
//  OrbitDock
//
//  Dashboard card showing usage for a single provider with gauges.
//

import SwiftUI

/// Dashboard card showing provider usage with circular gauges
struct ProviderUsageCard: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let planName: String?
  let isLoading: Bool
  let error: (any LocalizedError)?

  /// Check if error is API key mode (for Codex)
  var isApiKeyMode: Bool {
    guard let error else { return false }
    return error.localizedDescription.contains("API key")
  }

  var body: some View {
    HStack(spacing: Spacing.lg) {
      // Provider branding
      VStack(spacing: Spacing.xxs) {
        Image(systemName: provider.icon)
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .frame(width: 36)

      if !windows.isEmpty {
        ForEach(windows) { window in
          GenericUsageGauge(window: window, provider: provider)
        }

        // Plan badge (if known)
        if let plan = planName {
          VStack(spacing: Spacing.xs) {
            Text(plan)
              .font(.system(size: TypeScale.mini, weight: .bold))
              .foregroundStyle(provider.accentColor)

            Text("Plan")
              .font(.system(size: 8, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }
          .padding(.leading, Spacing.xs)
        }
      } else if isLoading {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Loading...")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
        }
      } else if let error {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: errorIcon)
            .font(.system(size: 12))
            .foregroundStyle(isApiKeyMode ? provider.accentColor : Color.statusError)
          Text(errorLabel)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textTertiary)
        }
        .help(error.localizedDescription)
      } else {
        // Empty state - show placeholder gauge
        GenericUsageGauge(
          window: RateLimitWindow(id: "empty", label: "--", utilization: 0, resetsAt: nil, windowDuration: 3_600),
          provider: provider
        )
      }
    }
    .padding(.vertical, Spacing.md_)
    .padding(.horizontal, Spacing.lg_)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
    .help(helpText)
  }

  private var errorIcon: String {
    guard let error else { return "exclamationmark.triangle" }
    let desc = error.localizedDescription.lowercased()
    if desc.contains("not installed") { return "xmark.circle" }
    if desc.contains("not logged") { return "person.crop.circle.badge.xmark" }
    if desc.contains("api key") { return "key.fill" }
    return "exclamationmark.triangle"
  }

  private var errorLabel: String {
    guard let error else { return "Error" }
    let desc = error.localizedDescription.lowercased()
    if desc.contains("token expired") { return "Token Expired" }
    if desc.contains("no claude credentials") { return "No Credentials" }
    if desc.contains("missing"), desc.contains("scope") { return "Missing Scope" }
    if desc.contains("unauthorized") { return "Unauthorized" }
    if desc.contains("not installed") { return "Not Installed" }
    if desc.contains("not logged") { return "Not Logged In" }
    if desc.contains("api key") { return "API Key" }
    return "Error"
  }

  private var helpText: String {
    guard !windows.isEmpty else {
      if let error {
        return error.localizedDescription
      }
      return "Loading \(provider.displayName) usage..."
    }

    var lines: [String] = []
    for window in windows {
      var text = "\(window.label): \(Int(window.utilization))% used"
      if let resets = window.resetsInDescription {
        text += " (resets in \(resets))"
      }
      if window.paceStatus != .unknown {
        text += "\n  Pace: \(window.paceStatus.rawValue)"
        if window.projectedAtReset > window.utilization {
          text += " → projected \(Int(window.projectedAtReset.rounded()))% at reset"
        }
      }
      lines.append(text)
    }

    if let plan = planName {
      lines.append("\nPlan: \(plan)")
    }

    return lines.joined(separator: "\n\n")
  }
}

#Preview {
  VStack(spacing: Spacing.md) {
    ProviderUsageCard(
      provider: .claude,
      windows: [
        .fiveHour(utilization: 45, resetsAt: Date().addingTimeInterval(3_600)),
        .sevenDay(utilization: 65, resetsAt: Date().addingTimeInterval(86_400)),
      ],
      planName: "Max 5x",
      isLoading: false,
      error: nil
    )

    ProviderUsageCard(
      provider: .codex,
      windows: [
        .fromMinutes(id: "primary", utilization: 30, windowMinutes: 15, resetsAt: Date().addingTimeInterval(600)),
      ],
      planName: nil,
      isLoading: false,
      error: nil
    )

    ProviderUsageCard(
      provider: .codex,
      windows: [],
      planName: nil,
      isLoading: true,
      error: nil
    )
  }
  .padding()
  .background(Color.backgroundPrimary)
}
