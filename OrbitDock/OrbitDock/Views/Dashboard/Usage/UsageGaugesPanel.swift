//
//  UsageGaugesPanel.swift
//  OrbitDock
//
//  Usage gauge components for displaying rate limit utilization.
//  Used by sidebar, status bar, and stats popover.
//

import SwiftUI

// MARK: - Usage Gauges Panel

struct UsageGaugesPanel: View {
  var axis: Axis = .horizontal
  let registry = UsageServiceRegistry.shared

  private var activeProviders: [(provider: Provider, windows: [RateLimitWindow], isLoading: Bool)] {
    registry.allProviders.map { provider in
      (provider: provider, windows: registry.windows(for: provider), isLoading: registry.isLoading(for: provider))
    }
  }

  var body: some View {
    Group {
      if axis == .vertical {
        verticalLayout
      } else {
        horizontalLayout
      }
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.sm_)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.4))
    )
  }

  private var horizontalLayout: some View {
    HStack(spacing: 0) {
      ForEach(Array(activeProviders.enumerated()), id: \.element.provider.id) { index, entry in
        if index > 0 {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
            .frame(width: 1)
            .padding(.vertical, Spacing.xs)
            .padding(.horizontal, Spacing.md)
        }

        ProviderGaugeMini(
          provider: entry.provider,
          windows: entry.windows,
          isLoading: entry.isLoading
        )
      }
    }
  }

  private var verticalLayout: some View {
    VStack(spacing: 0) {
      ForEach(Array(activeProviders.enumerated()), id: \.element.provider.id) { index, entry in
        if index > 0 {
          Rectangle()
            .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
            .frame(height: 1)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.sm_)
        }

        ProviderGaugeCompact(
          provider: entry.provider,
          windows: entry.windows,
          isLoading: entry.isLoading
        )
      }
    }
  }
}

// MARK: - Provider Gauge Mini (desktop inline)

private struct ProviderGaugeMini: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let isLoading: Bool

  private var hasData: Bool {
    !windows.isEmpty || isLoading
  }

  var body: some View {
    HStack(spacing: hasData ? Spacing.lg_ : Spacing.sm_) {
      // Provider icon + name
      HStack(spacing: Spacing.sm_) {
        Image(systemName: provider.icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textSecondary)
          .fixedSize()
      }

      if !windows.isEmpty {
        HStack(spacing: Spacing.lg_) {
          ForEach(windows) { window in
            MiniGauge(window: window, provider: provider)
          }
        }
      } else if isLoading {
        ProgressView()
          .controlSize(.mini)
      } else {
        Text("—")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .padding(.horizontal, Spacing.sm)
  }
}

// MARK: - Provider Gauge Compact (phone row)

private struct ProviderGaugeCompact: View {
  let provider: Provider
  let windows: [RateLimitWindow]
  let isLoading: Bool

  var body: some View {
    HStack(spacing: Spacing.md_) {
      // Provider icon + name
      HStack(spacing: Spacing.sm_) {
        Image(systemName: provider.icon)
          .font(.system(size: TypeScale.mini, weight: .bold))
          .foregroundStyle(provider.accentColor)

        Text(provider.displayName)
          .font(.system(size: TypeScale.caption, weight: .bold))
          .foregroundStyle(Color.textSecondary)
          .fixedSize()
      }
      .frame(minWidth: 60, alignment: .leading)

      if !windows.isEmpty {
        HStack(spacing: Spacing.sm) {
          ForEach(windows) { window in
            compactGaugePill(window)
          }
        }
      } else if isLoading {
        ProgressView()
          .controlSize(.mini)
      } else {
        Text("—")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textQuaternary)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.sm)
  }

  private func compactGaugePill(_ window: RateLimitWindow) -> some View {
    let usageColor = provider.color(for: window.utilization)

    return HStack(spacing: Spacing.xs) {
      Text(window.label)
        .font(.system(size: TypeScale.mini, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: false
      )
      .frame(width: 40, height: 4)

      Text("\(Int(window.utilization))%")
        .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
        .foregroundStyle(usageColor)
        .fixedSize()
    }
    .padding(.horizontal, Spacing.sm_)
    .padding(.vertical, Spacing.xs)
    .background(Color.backgroundSecondary.opacity(0.5), in: Capsule())
  }
}

// MARK: - Mini Gauge (individual window)

private struct MiniGauge: View {
  let window: RateLimitWindow
  let provider: Provider

  private var usageColor: Color {
    provider.color(for: window.utilization)
  }

  private var showProjection: Bool {
    window.projectedAtReset > window.utilization + 5
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      // Label + percentage
      HStack(spacing: Spacing.sm_) {
        Text(window.label)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .fixedSize()

        Text("\(Int(window.utilization))%")
          .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
          .foregroundStyle(usageColor)
          .fixedSize()
      }

      // Progress bar with projection
      UsageGaugeBar(
        utilization: window.utilization,
        usageColor: usageColor,
        projectedAtReset: window.projectedAtReset,
        showProjection: showProjection
      )
      .frame(width: 70, height: 5)

      // Pace + projection
      HStack(spacing: Spacing.xs) {
        if let pace = DashboardFormatters.paceLabel(window.paceStatus) {
          Text(pace)
            .font(.system(size: TypeScale.mini, weight: .medium))
            .foregroundStyle(DashboardFormatters.projectedColor(window.projectedAtReset))
        }

        if showProjection {
          Text("→\(Int(window.projectedAtReset.rounded()))%")
            .font(.system(size: TypeScale.mini, weight: .medium, design: .monospaced))
            .foregroundStyle(DashboardFormatters.projectedColor(window.projectedAtReset).opacity(0.8))
        }
      }
      .fixedSize()
    }
  }
}
