//
//  CodexUsageView.swift
//  OrbitDock
//
//  Codex/ChatGPT usage display components
//

import SwiftUI

// MARK: - Compact Inline View (for header)

struct CodexUsageCompact: View {
  let service = CodexUsageService.shared

  var body: some View {
    HStack(spacing: 8) {
      // Codex logo/icon
      Image(systemName: "sparkle")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(Color.codexAccent)

      if let usage = service.usage, let primary = usage.primary {
        CodexBarCompact(
          utilization: primary.usedPercent,
          resetsIn: primary.resetsInDescription
        )
      } else if service.isLoading {
        ProgressView()
          .controlSize(.mini)
      } else if let error = service.error {
        let isApiKey = { if case .apiKeyMode = error { return true }; return false }()
        HStack(spacing: 3) {
          Image(systemName: isApiKey ? "key.fill" : "exclamationmark.triangle")
            .font(.system(size: 9))
            .foregroundStyle(isApiKey ? Color.codexAccent : Color.statusError)
          if isApiKey {
            Text("API")
              .font(.system(size: 9, weight: .medium))
              .foregroundStyle(.tertiary)
          }
        }
        .help(error.localizedDescription)
      }
    }
    .opacity(service.isStale ? 0.6 : 1.0)
  }
}

struct CodexBarCompact: View {
  let utilization: Double
  let resetsIn: String

  private var progressColor: Color {
    if utilization >= 90 { return .statusError }
    if utilization >= 70 { return .statusWaiting }
    return .codexAccent
  }

  private var helpText: String {
    "Codex: \(Int(utilization))% used • resets in \(resetsIn)"
  }

  var body: some View {
    HStack(spacing: 5) {
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

// MARK: - Dashboard Card

struct CodexUsageCard: View {
  let service = CodexUsageService.shared

  var body: some View {
    HStack(spacing: 16) {
      // Codex branding
      VStack(spacing: 2) {
        Image(systemName: "sparkle")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(Color.codexAccent)

        Text("Codex")
          .font(.system(size: 8, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .frame(width: 36)

      if let usage = service.usage, let primary = usage.primary {
        CodexGauge(
          value: primary.usedPercent,
          windowMins: primary.windowDurationMins,
          resetsIn: primary.resetsInDescription,
          resetsAt: primary.resetsAt,
          paceStatus: primary.paceStatus,
          projectedUsage: primary.projectedAtReset
        )

        if let secondary = usage.secondary {
          CodexGauge(
            value: secondary.usedPercent,
            windowMins: secondary.windowDurationMins,
            resetsIn: secondary.resetsInDescription,
            resetsAt: secondary.resetsAt,
            paceStatus: secondary.paceStatus,
            projectedUsage: secondary.projectedAtReset
          )
        }
      } else if service.isLoading {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Connecting...")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
      } else if let error = service.error {
        HStack(spacing: 6) {
          Image(systemName: errorIcon(for: error))
            .font(.system(size: 12))
            .foregroundStyle(isApiKeyMode(error) ? Color.codexAccent : Color.statusError)
          Text(errorLabel(for: error))
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .help(error.localizedDescription)
      } else {
        CodexGauge(value: 0, windowMins: 15, resetsIn: nil, resetsAt: nil)
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .help(helpText)
  }

  private func errorIcon(for error: CodexUsageError) -> String {
    switch error {
      case .notInstalled: "xmark.circle"
      case .notLoggedIn: "person.crop.circle.badge.xmark"
      case .apiKeyMode: "key.fill"
      default: "exclamationmark.triangle"
    }
  }

  private func errorLabel(for error: CodexUsageError) -> String {
    switch error {
      case .notInstalled: "Not Installed"
      case .notLoggedIn: "Not Logged In"
      case .apiKeyMode: "API Key"
      default: "Error"
    }
  }

  private func isApiKeyMode(_ error: CodexUsageError) -> Bool {
    if case .apiKeyMode = error { return true }
    return false
  }

  private var helpText: String {
    guard let usage = service.usage, let primary = usage.primary else {
      if let error = service.error {
        return error.localizedDescription
      }
      return "Loading Codex usage..."
    }

    var text = "Codex usage: \(Int(primary.usedPercent))% used"
    text += " (resets in \(primary.resetsInDescription))"

    let pace = primary.paceStatus
    if pace != .unknown {
      text += "\nPace: \(pace.rawValue)"
      if primary.projectedAtReset > primary.usedPercent {
        text += " → projected \(Int(primary.projectedAtReset))% at reset"
      }
    }

    return text
  }
}

// MARK: - Circular Gauge

struct CodexGauge: View {
  let value: Double
  let windowMins: Int
  let resetsIn: String?
  var resetsAt: Date?
  var paceStatus: CodexUsage.RateLimit.PaceStatus?
  var projectedUsage: Double?

  private let size: CGFloat = 44
  private let lineWidth: CGFloat = 4

  private var windowLabel: String {
    if windowMins >= 60 {
      return "\(windowMins / 60)h"
    }
    return "\(windowMins)m"
  }

  private var resetsAtFormatted: String? {
    guard let resetsAt else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: resetsAt)
  }

  private var color: Color {
    if value >= 90 { return .statusError }
    if value >= 70 { return .statusWaiting }
    return .codexAccent
  }

  private var paceColor: Color {
    guard let pace = paceStatus else { return .secondary }
    switch pace {
      case .unknown: return .secondary
      case .relaxed: return .codexAccent
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

        // Projected usage indicator
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
        Text(windowLabel)
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

struct CodexMenuBarSection: View {
  let service = CodexUsageService.shared

  var body: some View {
    HStack(spacing: 0) {
      // Codex branding
      HStack(spacing: 4) {
        Image(systemName: "sparkle")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.codexAccent)

        Text("Codex")
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)
      }
      .frame(width: 60, alignment: .leading)

      if let usage = service.usage, let primary = usage.primary {
        CodexMenuBarGauge(
          value: primary.usedPercent,
          windowMins: primary.windowDurationMins,
          resetsIn: primary.resetsInDescription,
          resetsAt: primary.resetsAt,
          paceStatus: primary.paceStatus,
          projectedUsage: primary.projectedAtReset
        )
      } else if service.isLoading {
        HStack {
          Spacer()
          ProgressView()
            .controlSize(.small)
          Spacer()
        }
      } else if let error = service.error {
        let isApiKey = { if case .apiKeyMode = error { return true }; return false }()
        HStack(spacing: 4) {
          if isApiKey {
            Image(systemName: "key.fill")
              .font(.system(size: 9))
              .foregroundStyle(Color.codexAccent)
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

struct CodexMenuBarGauge: View {
  let value: Double
  let windowMins: Int
  let resetsIn: String
  let resetsAt: Date?
  var paceStatus: CodexUsage.RateLimit.PaceStatus?
  var projectedUsage: Double?

  private var windowLabel: String {
    if windowMins >= 60 {
      return "\(windowMins / 60)h window"
    }
    return "\(windowMins)m window"
  }

  private var resetsAtFormatted: String? {
    guard let resetsAt else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: resetsAt)
  }

  private var willExceed: Bool {
    guard let projected = projectedUsage else { return false }
    return projected > 95
  }

  private var projectedColor: Color {
    guard let projected = projectedUsage else { return .secondary }
    if projected > 100 { return .statusError }
    if projected > 90 { return .statusWaiting }
    return .statusSuccess
  }

  private var color: Color {
    if value >= 90 { return .statusError }
    if value >= 70 { return .statusWaiting }
    return .codexAccent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      // Label row
      HStack {
        Text(windowLabel)
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.secondary)

        if willExceed {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.statusError)
        }

        Spacer()

        Text("\(Int(value))%")
          .font(.system(size: 11, weight: .bold, design: .monospaced))
          .foregroundStyle(color)

        if let projected = projectedUsage, projected > value + 5 {
          Text("→ \(Int(projected))%")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(projectedColor)
        }

        if let resetTime = resetsAtFormatted {
          Text("@ \(resetTime)")
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.tertiary)
        }
      }

      // Progress bar
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.08))

          if let projected = projectedUsage, projected > value {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(projectedColor.opacity(willExceed ? 0.5 : 0.35))
              .frame(width: geo.size.width * min(1, projected / 100))
          }

          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: geo.size.width * min(1, value / 100))
        }
      }
      .frame(height: 4)
    }
    .frame(maxWidth: .infinity)
  }
}

// MARK: - Color Extension

extension Color {
  /// Codex accent color (OpenAI green)
  static let codexAccent = Color(red: 0.29, green: 0.78, blue: 0.56) // #4AC78F
}

// MARK: - Previews

#Preview("Compact") {
  HStack(spacing: 20) {
    CodexUsageCompact()
  }
  .padding()
  .background(Color.backgroundSecondary)
}

#Preview("Card") {
  CodexUsageCard()
    .frame(width: 280)
    .padding()
    .background(Color.backgroundPrimary)
}

#Preview("Menu Bar") {
  CodexMenuBarSection()
    .frame(width: 280)
    .padding()
    .background(Color.backgroundPrimary)
}
