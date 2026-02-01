//
//  SubscriptionUsageView.swift
//  OrbitDock
//
//  Compact subscription usage display showing 5-hour and 7-day limits
//

import SwiftUI

// MARK: - Compact Inline View (for header)

struct SubscriptionUsageCompact: View {
  let service = SubscriptionUsageService.shared

  var body: some View {
    HStack(spacing: 12) {
      if let usage = service.usage {
        // 5-hour bar
        UsageBarCompact(
          label: "5h",
          utilization: usage.fiveHour.utilization,
          resetsIn: usage.fiveHour.resetsInDescription
        )

        // 7-day bar (if available)
        if let sevenDay = usage.sevenDay {
          UsageBarCompact(
            label: "7d",
            utilization: sevenDay.utilization,
            resetsIn: sevenDay.resetsInDescription
          )
        }
      } else if service.isLoading {
        ProgressView()
          .controlSize(.mini)
      } else if service.error != nil {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 10))
          .foregroundStyle(Color.statusError)
          .help(service.error?.localizedDescription ?? "Error loading usage")
      }
    }
    .opacity(service.isStale ? 0.6 : 1.0)
  }
}

struct UsageBarCompact: View {
  let label: String
  let utilization: Double
  let resetsIn: String?

  private var progressColor: Color {
    if utilization >= 90 { return .statusError }
    if utilization >= 70 { return .statusWaiting }
    return .accent
  }

  private var helpText: String {
    var text = "\(label): \(Int(utilization))% used"
    if let resets = resetsIn {
      text += " • resets in \(resets)"
    }
    return text
  }

  var body: some View {
    HStack(spacing: 5) {
      Text(label)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.tertiary)

      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))

          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * min(1, utilization / 100))
        }
      }
      .frame(width: 28, height: 4)

      Text("\(Int(utilization))%")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(progressColor)
    }
    .help(helpText)
  }
}

// MARK: - Expanded View (for dashboard or popover)

struct SubscriptionUsageExpanded: View {
  let service = SubscriptionUsageService.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Header
      HStack {
        Text("Subscription Usage")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)

        Spacer()

        if let plan = service.usage?.planName {
          Text(plan)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accent.opacity(0.15), in: Capsule())
        }

        if service.isLoading {
          ProgressView()
            .controlSize(.mini)
        }
      }

      if let usage = service.usage {
        VStack(spacing: 10) {
          // 5-hour session
          UsageRowExpanded(
            icon: "clock",
            label: "Session (5h)",
            window: usage.fiveHour
          )

          // 7-day overall
          if let sevenDay = usage.sevenDay {
            UsageRowExpanded(
              icon: "calendar",
              label: "Weekly (7d)",
              window: sevenDay
            )
          }

          // Sonnet-specific (if present and different)
          if let sonnet = usage.sevenDaySonnet, sonnet.utilization > 0 {
            UsageRowExpanded(
              icon: "wand.and.stars",
              label: "Sonnet (7d)",
              window: sonnet,
              color: .modelSonnet
            )
          }

          // Opus-specific (if present)
          if let opus = usage.sevenDayOpus, opus.utilization > 0 {
            UsageRowExpanded(
              icon: "sparkles",
              label: "Opus (7d)",
              window: opus,
              color: .modelOpus
            )
          }
        }
      } else if let error = service.error {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Color.statusError)

          Text(error.localizedDescription)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
      }

      // Last updated
      if let fetched = service.usage?.fetchedAt {
        Text("Updated \(fetched.formatted(.relative(presentation: .named)))")
          .font(.system(size: 9))
          .foregroundStyle(.quaternary)
      }
    }
    .padding(12)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }
}

struct UsageRowExpanded: View {
  let icon: String
  let label: String
  let window: SubscriptionUsage.Window
  var color: Color = .accent

  private var progressColor: Color {
    if window.utilization >= 90 { return .statusError }
    if window.utilization >= 70 { return .statusWaiting }
    return color
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: icon)
          .font(.system(size: 10))
          .foregroundStyle(.tertiary)

        Text(label)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        Spacer()

        Text("\(Int(window.utilization))%")
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(progressColor)

        if let resets = window.resetsInDescription {
          Text("• \(resets)")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
      }

      // Progress bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.primary.opacity(0.08))

          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(progressColor)
            .frame(width: geo.size.width * min(1, window.utilization / 100))
        }
      }
      .frame(height: 6)
    }
  }
}

// MARK: - Dashboard Card (Dual Gauge)

struct SubscriptionUsageCard: View {
  let service = SubscriptionUsageService.shared

  var body: some View {
    HStack(spacing: 16) {
      if let usage = service.usage {
        // 5-hour gauge with pace
        UsageGauge(
          value: usage.fiveHour.utilization,
          label: "5h",
          resetsIn: usage.fiveHour.resetsInDescription,
          resetsAt: usage.fiveHour.resetsAt,
          paceStatus: usage.fiveHour.paceStatus,
          projectedUsage: usage.fiveHour.projectedAtReset
        )

        // 7-day gauge with pace (if available)
        if let sevenDay = usage.sevenDay {
          UsageGauge(
            value: sevenDay.utilization,
            label: "7d",
            resetsIn: sevenDay.resetsInDescription,
            resetsAt: sevenDay.resetsAt,
            paceStatus: sevenDay.paceStatus,
            projectedUsage: sevenDay.projectedAtReset
          )
        }

        // Plan badge (if known)
        if let plan = usage.planName {
          VStack(spacing: 4) {
            Text(plan)
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(Color.accent)

            Text("Plan")
              .font(.system(size: 8, weight: .medium))
              .foregroundStyle(.quaternary)
          }
          .padding(.leading, 4)
        }
      } else if service.isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Loading...")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      } else if service.error != nil {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundStyle(Color.statusError)
          Text("API Error")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      } else {
        UsageGauge(value: 0, label: "5h", resetsIn: nil, resetsAt: nil)
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .help(helpText)
  }

  private var helpText: String {
    guard let usage = service.usage else {
      if let error = service.error {
        return error.localizedDescription
      }
      return "Loading subscription usage..."
    }

    var text = "5-hour session: \(Int(usage.fiveHour.utilization))% used"
    if let resets = usage.fiveHour.resetsInDescription {
      text += " (resets in \(resets))"
    }
    let pace5h = usage.fiveHour.paceStatus
    if pace5h != .unknown {
      text += "\n  Pace: \(pace5h.rawValue)"
      if usage.fiveHour.projectedAtReset > usage.fiveHour.utilization {
        text += " → projected \(Int(usage.fiveHour.projectedAtReset))% at reset"
      }
    }

    if let sevenDay = usage.sevenDay {
      text += "\n\n7-day rolling: \(Int(sevenDay.utilization))% used"
      if let resets = sevenDay.resetsInDescription {
        text += " (resets in \(resets))"
      }
      let pace7d = sevenDay.paceStatus
      if pace7d != .unknown {
        text += "\n  Pace: \(pace7d.rawValue)"
        if sevenDay.projectedAtReset > sevenDay.utilization {
          text += " → projected \(Int(sevenDay.projectedAtReset))% at reset"
        }
      }
    }

    if let plan = usage.planName {
      text += "\n\nPlan: \(plan)"
    }
    return text
  }
}

// MARK: - Circular Gauge Component

struct UsageGauge: View {
  let value: Double // 0-100
  let label: String
  let resetsIn: String?
  var resetsAt: Date?
  var paceStatus: SubscriptionUsage.Window.PaceStatus?
  var projectedUsage: Double?

  private let size: CGFloat = 44
  private let lineWidth: CGFloat = 4

  /// Format reset time as "3:45 PM" or "Mon 3:45 PM" for 7d
  private var resetsAtFormatted: String? {
    guard let resetsAt else { return nil }
    let formatter = DateFormatter()
    if label == "7d", !Calendar.current.isDateInToday(resetsAt) {
      formatter.dateFormat = "EEE h:mm a"
    } else {
      formatter.dateFormat = "h:mm a"
    }
    return formatter.string(from: resetsAt)
  }

  private var color: Color {
    if value >= 90 { return .statusError }
    if value >= 70 { return .statusWaiting }
    return .accent
  }

  private var paceColor: Color {
    guard let pace = paceStatus else { return .secondary }
    switch pace {
      case .unknown: return .secondary
      case .relaxed: return .accent
      case .onTrack: return .statusSuccess
      case .borderline: return .statusWaiting
      case .exceeding, .critical: return .statusError
    }
  }

  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        // Background ring
        Circle()
          .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)

        // Projected usage indicator (faint)
        if let projected = projectedUsage, projected > value {
          Circle()
            .trim(from: min(1, value / 100), to: min(1, projected / 100))
            .stroke(
              paceColor.opacity(0.25),
              style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
        }

        // Progress arc
        Circle()
          .trim(from: 0, to: min(1, value / 100))
          .stroke(
            color,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(-90))

        // Center value
        Text("\(Int(value))")
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .foregroundStyle(color)
      }
      .frame(width: size, height: size)

      // Label + reset time
      VStack(spacing: 2) {
        Text(label)
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)

        if let resetTime = resetsAtFormatted {
          Text("@ \(resetTime)")
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .overlay(alignment: .topTrailing) {
      // Pace indicator badge
      if let pace = paceStatus, pace != .unknown {
        Image(systemName: pace.icon)
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(paceColor)
          .padding(2)
          .background(Color.backgroundTertiary, in: Circle())
          .offset(x: 4, y: -2)
      }
    }
  }
}

// MARK: - Menu Bar Section

struct MenuBarUsageSection: View {
  let service = SubscriptionUsageService.shared

  var body: some View {
    VStack(spacing: 8) {
      if let usage = service.usage {
        // 5h gauge with pace
        MenuBarGauge(
          value: usage.fiveHour.utilization,
          label: "5h Session",
          resetsIn: usage.fiveHour.resetsInDescription,
          resetsAt: usage.fiveHour.resetsAt,
          paceStatus: usage.fiveHour.paceStatus,
          projectedUsage: usage.fiveHour.projectedAtReset
        )

        // 7d gauge with pace
        if let sevenDay = usage.sevenDay {
          MenuBarGauge(
            value: sevenDay.utilization,
            label: "7d Rolling",
            resetsIn: sevenDay.resetsInDescription,
            resetsAt: sevenDay.resetsAt,
            paceStatus: sevenDay.paceStatus,
            projectedUsage: sevenDay.projectedAtReset
          )
        }
      } else if service.isLoading {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Text("Loading usage...")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
          Spacer()
        }
      } else if let error = service.error {
        HStack {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(Color.statusError)
          Text(error.localizedDescription)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

struct MenuBarGauge: View {
  let value: Double
  let label: String
  let resetsIn: String?
  let resetsAt: Date?
  var paceStatus: SubscriptionUsage.Window.PaceStatus?
  var projectedUsage: Double?

  /// Format reset time as "3:45 PM" or "Mon 3:45 PM" for 7d
  private var resetsAtFormatted: String? {
    guard let resetsAt else { return nil }
    let formatter = DateFormatter()
    if label == "7d Rolling", !Calendar.current.isDateInToday(resetsAt) {
      formatter.dateFormat = "EEE h:mm a"
    } else {
      formatter.dateFormat = "h:mm a"
    }
    return formatter.string(from: resetsAt)
  }

  /// Time until reset
  private var timeUntilReset: TimeInterval {
    guard let resetsAt else { return .infinity }
    return resetsAt.timeIntervalSinceNow
  }

  /// Color for reset time based on urgency
  private var resetTimeColor: Color {
    if timeUntilReset < 15 * 60 { return .statusError }
    if timeUntilReset < 60 * 60 { return .statusWaiting }
    return .secondary.opacity(0.6)
  }

  /// Will exceed limit?
  private var willExceed: Bool {
    guard let projected = projectedUsage else { return false }
    return projected > 95
  }

  /// Projected usage color
  private var projectedColor: Color {
    guard let projected = projectedUsage else { return .secondary }
    if projected > 100 { return .statusError }
    if projected > 90 { return .statusWaiting }
    return .statusSuccess
  }

  private var color: Color {
    if value >= 90 { return .statusError }
    if value >= 70 { return .statusWaiting }
    return .accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Label row
      HStack {
        Text(label)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)

        // Warning if will exceed
        if willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.statusError)
        }

        Spacer()

        Text("\(Int(value))%")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundStyle(color)

        // Projected usage
        if let projected = projectedUsage, projected > value + 5 {
          Text("→ \(Int(projected))%")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(projectedColor)
        }

        if let resetTime = resetsAtFormatted {
          Text("@ \(resetTime)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(resetTimeColor)
        }
      }

      // Progress bar with projection
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))

          // Projected usage (more visible)
          if let projected = projectedUsage, projected > value {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(projectedColor.opacity(willExceed ? 0.5 : 0.35))
              .frame(width: geo.size.width * min(1, projected / 100))
          }

          // Current usage
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: geo.size.width * min(1, value / 100))
        }
      }
      .frame(height: 4)
    }
  }
}

// MARK: - Menu Bar Badge

struct SubscriptionUsageBadge: View {
  let service = SubscriptionUsageService.shared

  var body: some View {
    if let usage = service.usage {
      let util = usage.fiveHour.utilization
      let color = badgeColor(util)

      HStack(spacing: 3) {
        Circle()
          .fill(color)
          .frame(width: 6, height: 6)

        Text("\(Int(util))%")
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(color)
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 3)
      .background(color.opacity(0.12), in: Capsule())
    }
  }

  private func badgeColor(_ utilization: Double) -> Color {
    if utilization >= 90 { return .statusError }
    if utilization >= 70 { return .statusWaiting }
    return .statusSuccess
  }
}

// MARK: - Previews

#Preview("Compact") {
  HStack(spacing: 20) {
    SubscriptionUsageCompact()
  }
  .padding()
  .background(Color.backgroundSecondary)
}

#Preview("Expanded") {
  SubscriptionUsageExpanded()
    .frame(width: 280)
    .padding()
    .background(Color.backgroundPrimary)
}

#Preview("Badge") {
  SubscriptionUsageBadge()
    .padding()
    .background(Color.backgroundSecondary)
}
